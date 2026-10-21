package com.secretsavior.vpn

import java.io.Closeable
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.TimeUnit

/**
 * Reenvía consultas DNS sin bloquear un hilo por consulta. Sin Android: se prueba suelto.
 *
 * Un único socket, protegido una sola vez, y un hilo que recibe. Cada consulta sale con un
 * identificador propio (para que dos apps con el mismo id no se crucen) y se le devuelve
 * el suyo al contestar. Así una página que pide cincuenta nombres a la vez no hace cola.
 *
 * - Se manda a la vez a los dos [primaries]: contesta el más rápido, y si se pierde un
 *   paquete —lo normal con datos móviles— el otro ya va en camino.
 * - Sin respuesta en [escalateAfterMs] se reintenta en todos, [fallbacks] incluidos.
 * - Sin respuesta en [giveUpAfterMs] se contesta null y el llamador manda SERVFAIL.
 * - Si los primarios fallan varias veces seguidas, durante un rato se pregunta a todos
 *   desde el principio en vez de esperar a cada consulta.
 *
 * El socket no se conecta a ninguna dirección a propósito: un socket UDP conectado se
 * queda con la ruta del momento y deja de funcionar al pasar de Wi-Fi a datos.
 */
class DnsForwarder(
    private val primaries: List<InetSocketAddress>,
    private val fallbacks: List<InetSocketAddress>,
    protect: (DatagramSocket) -> Unit,
    private val escalateAfterMs: Long = 800,
    private val giveUpAfterMs: Long = 4_000,
) : Closeable {

    private class Pending(val originalId: Int, val query: ByteArray, val done: (ByteArray?) -> Unit) {
        @Volatile
        var timer: ScheduledFuture<*>? = null
    }

    private val known = (primaries + fallbacks).toSet()
    private val everyone = primaries + fallbacks
    private val pending = ConcurrentHashMap<Int, Pending>()
    private val timers = ScheduledThreadPoolExecutor(1).apply {
        removeOnCancelPolicy = true
        setKeepAliveTime(10, TimeUnit.SECONDS)
        allowCoreThreadTimeOut(true) // sin consultas, sin hilo despierto
    }
    private val socket = DatagramSocket().also(protect)

    @Volatile
    private var closed = false

    // Sólo los toca el hilo de los temporizadores.
    private var lastEscalation = 0L
    private var escalationStreak = 0

    @Volatile
    private var primariesDownUntil = 0L

    private val receiver = Thread(::receiveLoop, "savior-dns").apply {
        isDaemon = true
        start()
    }

    /** [done] se llama una sola vez, desde otro hilo: con la respuesta o con null. */
    fun query(query: ByteArray, done: (ByteArray?) -> Unit) {
        if (closed || query.size < 12 || pending.size >= MAX_PENDING) {
            done(null)
            return
        }
        val p = Pending(u16(query, 0), query.copyOf(), done)
        var id: Int
        do {
            id = ThreadLocalRandom.current().nextInt(0x10000)
        } while (pending.putIfAbsent(id, p) != null)
        put16(p.query, 0, id)

        val primariesDown = now() < primariesDownUntil
        send(p.query, if (primariesDown) everyone else primaries)
        val queryId = id
        p.timer = timers.schedule(
            { if (primariesDown) expire(queryId, p) else escalate(queryId, p) },
            if (primariesDown) giveUpAfterMs else escalateAfterMs,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun escalate(id: Int, p: Pending) {
        if (pending[id] !== p) return
        val t = now()
        escalationStreak = if (t - lastEscalation < STREAK_WINDOW_MS) escalationStreak + 1 else 1
        lastEscalation = t
        if (escalationStreak >= STREAK_TO_MARK_DOWN) primariesDownUntil = t + DOWN_FOR_MS
        send(p.query, everyone)
        p.timer = timers.schedule({ expire(id, p) }, giveUpAfterMs - escalateAfterMs, TimeUnit.MILLISECONDS)
    }

    private fun expire(id: Int, p: Pending) {
        if (pending.remove(id, p)) finish(p, null)
    }

    private fun send(packet: ByteArray, to: List<InetSocketAddress>) {
        for (addr in to) {
            try {
                socket.send(DatagramPacket(packet, packet.size, addr))
            } catch (e: IOException) {
                // Sin red en este instante: el temporizador decidirá.
            }
        }
    }

    private fun receiveLoop() {
        val buf = ByteArray(MAX_RESPONSE)
        val packet = DatagramPacket(buf, buf.size)
        while (!closed) {
            try {
                packet.length = buf.size
                socket.receive(packet)
            } catch (e: IOException) {
                if (closed) break
                continue
            }
            if (packet.length < 12 || packet.socketAddress !in known) continue
            val p = pending.remove(u16(buf, 0)) ?: continue // tardía o duplicada
            p.timer?.cancel(false)
            val response = buf.copyOf(packet.length)
            put16(response, 0, p.originalId)
            finish(p, response)
        }
    }

    private fun finish(p: Pending, response: ByteArray?) {
        try {
            p.done(response)
        } catch (e: Exception) {
            // un fallo al contestar una consulta no debe tumbar las demás
        }
    }

    override fun close() {
        closed = true
        socket.close()
        timers.shutdownNow()
        pending.clear()
        receiver.interrupt()
    }

    private fun now() = System.nanoTime() / 1_000_000

    private companion object {
        const val MAX_PENDING = 2048
        const val MAX_RESPONSE = 4096
        const val STREAK_WINDOW_MS = 10_000L
        const val STREAK_TO_MARK_DOWN = 3
        const val DOWN_FOR_MS = 30_000L

        fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

        fun put16(b: ByteArray, o: Int, v: Int) {
            b[o] = (v shr 8).toByte()
            b[o + 1] = v.toByte()
        }
    }
}
