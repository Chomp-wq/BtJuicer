package com.secretsavior.vpn

import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Reenvía consultas DNS sin bloquear un hilo por consulta. Sin Android: se prueba suelto.
 *
 * Un único socket, protegido una sola vez, y un hilo que recibe. Cada consulta sale con un
 * identificador propio (para que dos apps con el mismo id no se crucen) y se le devuelve
 * el suyo al contestar. Así una página que pide cincuenta nombres a la vez no hace cola.
 *
 * Una respuesta sólo se acepta si cumple las tres: viene de un servidor al que se preguntó por
 * esa consulta, es de la misma pregunta (nombre, tipo y clase) y todavía hay quien la espera. El
 * identificador, de 16 bits, no basta: se pregunta a varios servidores a la vez y las respuestas
 * repetidas llegan tarde, y una de ellas podía coincidir con el id de OTRA consulta en vuelo y
 * entregarse como suya; el cliente la descarta por no ser su pregunta y se queda esperando una
 * respuesta que ya no llega, con segundos de parón.
 *
 * - Se manda a la vez a los [primaries]: contesta el más rápido, y si se pierde un
 *   paquete —lo normal con datos móviles— los otros ya van en camino.
 * - Sin respuesta en [escalateAfterMs] se reintenta en todos, [fallbacks] incluidos.
 * - Sin respuesta en [giveUpAfterMs] se contesta null y el llamador manda SERVFAIL.
 * - Si los primarios fallan varias veces seguidas, durante un rato se pregunta a todos
 *   desde el principio en vez de esperar a cada consulta.
 * - Si la respuesta llega cortada (TC) se repite la consulta por TCP al mismo servidor: el
 *   túnel no sirve DNS por TCP, y sin esto esa búsqueda fallaba en el cliente.
 *
 * - Con [cache], lo que ya se preguntó se contesta al momento, sin ir a la red; si estaba
 *   caducada o está a punto de caducar se renueva en segundo plano, una sola vez por pregunta
 *   (ver [DnsCache]). Es lo que quita la espera de ida y vuelta a casi todas las conexiones.
 *
 * El socket no se conecta a ninguna dirección a propósito: un socket UDP conectado se
 * queda con la ruta del momento y deja de funcionar al pasar de Wi-Fi a datos.
 */
class DnsForwarder(
    private val primaries: List<InetSocketAddress>,
    private val fallbacks: List<InetSocketAddress>,
    private val protect: (DatagramSocket) -> Unit,
    private val protectTcp: (Socket) -> Unit = {},
    private val escalateAfterMs: Long = 800,
    private val giveUpAfterMs: Long = 4_000,
    /** null desactiva la caché: cada consulta va a la red. */
    private val cache: DnsCache? = DnsCache(),
    /** Se llama al arrancar cada hilo propio (receptor y TCP); en Android sirve para subirles la prioridad. */
    private val onThreadStart: () -> Unit = {},
) : Closeable {

    private class Pending(
        val originalId: Int,
        /** La consulta con nuestro identificador. */
        val query: ByteArray,
        /** Su pregunta, para comprobar que la respuesta es de esta consulta. */
        val key: String?,
        val sentAt: Long,
        val done: (ByteArray?) -> Unit,
    ) {
        @Volatile
        var timer: ScheduledFuture<*>? = null

        /** A quién se le preguntó: sólo de ellos se acepta respuesta. */
        val sentTo: MutableSet<InetSocketAddress> = ConcurrentHashMap.newKeySet()
    }

    private val everyone = primaries + fallbacks
    private val pending = ConcurrentHashMap<Int, Pending>()
    private val timers = ScheduledThreadPoolExecutor(1).apply {
        removeOnCancelPolicy = true
        setKeepAliveTime(10, TimeUnit.SECONDS)
        allowCoreThreadTimeOut(true) // sin consultas, sin hilo despierto
    }
    private val tcpPool = ThreadPoolExecutor(
        TCP_THREADS, TCP_THREADS, 10, TimeUnit.SECONDS, LinkedBlockingQueue(TCP_QUEUE),
        { r -> Thread({ onThreadStart(); r.run() }, "savior-dns-tcp").apply { isDaemon = true } },
    ).apply { allowCoreThreadTimeOut(true) }

    @Volatile
    private var socket: DatagramSocket = newSocket()

    @Volatile
    private var closed = false

    // Sólo los toca el hilo de los temporizadores.
    private var lastEscalation = 0L
    private var escalationStreak = 0

    @Volatile
    private var primariesDownUntil = 0L

    /** Preguntas que se están renovando en segundo plano: una sola renovación por pregunta. */
    private val refreshing = ConcurrentHashMap.newKeySet<String>()

    /** Hasta cuándo no se envía a direcciones IPv6 (porque el último envío falló). */
    @Volatile
    private var noIpv6Until = Long.MIN_VALUE

    // Antes que el hilo receptor: él los usa en cuanto arranca.
    private val averageMicros = AtomicLong(0)
    private val answeredCount = AtomicInteger()
    private val failed = AtomicInteger()
    private val recent = BooleanArray(RECENT)
    private var recentPos = 0
    private var recentSeen = 0

    private val receiver = Thread({ onThreadStart(); receiveLoop() }, "savior-dns").apply {
        isDaemon = true
        start()
    }

    private fun newSocket(): DatagramSocket = DatagramSocket().also {
        // Una página que resuelve decenas de nombres, cada uno enviado a varios servidores, trae
        // ráfagas de respuestas; con el búfer por defecto algunas se pierden y cuestan los 800 ms
        // de la escalada. Si el sistema no deja, se queda con el suyo.
        try {
            it.receiveBufferSize = 1 shl 20
        } catch (e: Exception) {
        }
        protect(it)
    }

    /** Para las pruebas: el socket en uso, por si hay que romperlo. */
    internal fun currentSocket(): DatagramSocket = socket

    /**
     * [done] se llama una sola vez: con la respuesta o con null. Desde otro hilo si va a la red;
     * si sale de la caché, desde el hilo que llama, que así no espera nada.
     */
    fun query(query: ByteArray, done: (ByteArray?) -> Unit) {
        if (closed || query.size < 12) {
            done(null)
            return
        }
        val hit = cache?.lookup(query)
        if (hit != null) {
            try {
                done(hit.response)
            } catch (e: Exception) {
                // igual que en finish: un fallo al contestar no debe tumbar al llamador
            }
            if (hit.needsRefresh) refresh(query)
            return
        }
        forward(query, done)
    }

    /**
     * Renueva en segundo plano la pregunta de [query]: una consulta normal cuya respuesta nadie
     * espera; [accept] ya la deja en la caché. Si ya hay una renovación en marcha no se repite.
     */
    private fun refresh(query: ByteArray) {
        val key = DnsPacket.questionKey(query) ?: return
        if (!refreshing.add(key)) return
        forward(query.copyOf()) { refreshing.remove(key) }
    }

    private fun forward(query: ByteArray, done: (ByteArray?) -> Unit) {
        if (pending.size >= MAX_PENDING) {
            done(null)
            return
        }
        val p = Pending(u16(query, 0), query.copyOf(), DnsPacket.questionKey(query), now(), done)
        var id: Int
        do {
            id = ThreadLocalRandom.current().nextInt(0x10000)
        } while (pending.putIfAbsent(id, p) != null)
        put16(p.query, 0, id)

        val primariesDown = now() < primariesDownUntil
        send(p, if (primariesDown) everyone else primaries)
        val queryId = id
        try {
            p.timer = timers.schedule(
                { if (primariesDown) expire(queryId, p) else escalate(queryId, p) },
                if (primariesDown) giveUpAfterMs else escalateAfterMs,
                TimeUnit.MILLISECONDS,
            )
        } catch (e: RejectedExecutionException) {
            // close() se cruzó con esta consulta
            expire(queryId, p)
        }
    }

    private fun escalate(id: Int, p: Pending) {
        if (pending[id] !== p) return
        val t = now()
        escalationStreak = if (t - lastEscalation < STREAK_WINDOW_MS) escalationStreak + 1 else 1
        lastEscalation = t
        if (escalationStreak >= STREAK_TO_MARK_DOWN) primariesDownUntil = t + DOWN_FOR_MS
        send(p, everyone)
        p.timer = timers.schedule({ expire(id, p) }, giveUpAfterMs - escalateAfterMs, TimeUnit.MILLISECONDS)
    }

    private fun expire(id: Int, p: Pending) {
        if (pending.remove(id, p)) {
            failed.incrementAndGet()
            outcome(false)
            finish(p, null)
        }
    }

    /** Tiempo medio de respuesta (media móvil), para verlo en la app y saber si el resolutor va lento. */
    val averageMs: Long get() = averageMicros.get() / 1000

    /** Para la interfaz: cuántas consultas se contestaron desde la caché y cuántas pasaron por ella. */
    val cacheHits: Int get() = cache?.let { it.hits + it.staleHits } ?: 0
    val cacheLookups: Int get() = cache?.let { it.hits + it.staleHits + it.misses } ?: 0

    /** Consultas contestadas y consultas que se quedaron sin respuesta, desde que arrancó. */
    val answered: Int get() = answeredCount.get()
    val unanswered: Int get() = failed.get()

    /** De las últimas [RECENT] consultas, cuántas se quedaron sin respuesta y cuántas hubo. */
    val recentFailed: Int get() = synchronized(recent) { (0 until minOf(recentSeen, RECENT)).count { !recent[it] } }
    val recentTotal: Int get() = synchronized(recent) { minOf(recentSeen, RECENT) }

    private fun outcome(ok: Boolean) = synchronized(recent) {
        recent[recentPos] = ok
        recentPos = (recentPos + 1) % RECENT
        recentSeen++
    }

    private fun noteLatency(ms: Long) {
        val sample = ms * 1000
        val n = answeredCount.incrementAndGet()
        // Las primeras se promedian sin más; luego pesa más lo reciente (1/32).
        averageMicros.updateAndGet { avg -> if (n <= 32) avg + (sample - avg) / n else avg + (sample - avg) / 32 }
        outcome(true)
    }

    private fun send(p: Pending, to: List<InetSocketAddress>) {
        // Sin IPv6 cada envío a un servidor IPv6 lanza una excepción, y crearlas no sale gratis en
        // el camino caliente: tras un fallo se dejan de usar un minuto. Si no hubiera otra cosa a
        // la que enviar se envía igualmente: nunca se deja una consulta sin destino.
        val skipV6 = now() < noIpv6Until && to.any { it.address !is Inet6Address }
        for (addr in to) {
            val v6 = addr.address is Inet6Address
            if (skipV6 && v6) continue
            p.sentTo.add(addr) // antes de enviar: la respuesta puede llegar al instante
            try {
                socket.send(DatagramPacket(p.query, p.query.size, addr))
            } catch (e: Exception) {
                if (v6) noIpv6Until = now() + IPV6_BACKOFF_MS
                // Sin red en este instante (IOException) o sin IPv6 en este sistema
                // (UnsupportedAddressTypeException, que no es de E/S): el temporizador decidirá.
                // Dejarla escapar tumbaría al hilo que llama, que puede ser el lector del túnel.
            }
        }
    }

    private fun receiveLoop() {
        val buf = ByteArray(MAX_RESPONSE)
        val packet = DatagramPacket(buf, buf.size)
        var errors = 0
        while (!closed) {
            try {
                packet.length = buf.size
                socket.receive(packet)
                errors = 0
            } catch (e: IOException) {
                if (closed) break
                // El socket puede estar roto (lo cerró el sistema, cambió la red). Sin esperar,
                // este bucle giraría a toda velocidad con un núcleo al 100 %; tras varios fallos
                // seguidos se crea un socket nuevo.
                errors++
                try {
                    Thread.sleep(minOf(MAX_BACKOFF_MS, 20L shl minOf(errors, 6)))
                } catch (ie: InterruptedException) {
                    break
                }
                if (errors >= REBUILD_AFTER || socket.isClosed) { // uno cerrado no se recupera solo
                    rebuildSocket()
                    errors = 0
                }
                continue
            }
            accept(buf, packet)
        }
    }

    private fun rebuildSocket() {
        try {
            val old = socket
            socket = newSocket()
            old.close()
        } catch (e: Exception) {
            // se reintenta en la siguiente vuelta
        }
    }

    private fun accept(buf: ByteArray, packet: DatagramPacket) {
        val len = packet.length
        if (len < 12 || !DnsPacket.isResponse(buf, len)) return
        val from = packet.socketAddress as? InetSocketAddress ?: return
        val id = u16(buf, 0)
        val p = pending[id] ?: return // tardía o repetida
        // Todas estas comprobaciones van ANTES de quitarla de la lista: una respuesta que no es
        // la buena no debe gastar la consulta, o la buena llegaría después a nadie.
        if (from !in p.sentTo) return
        if (p.key != null && DnsPacket.questionKey(buf, len) != p.key) return
        if (!pending.remove(id, p)) return

        p.timer?.cancel(false)
        noteLatency(now() - p.sentAt)
        val response = buf.copyOf(len)
        cache?.store(p.query, response) // antes de contestar: la siguiente consulta ya la encuentra
        put16(response, 0, p.originalId)
        if (DnsPacket.isTruncated(response)) tcpFallback(p, from, response) else finish(p, response)
    }

    /** La respuesta llegó cortada: se repite por TCP a quien contestó, y si no se puede, se entrega cortada. */
    private fun tcpFallback(p: Pending, server: InetSocketAddress, truncated: ByteArray) {
        // Lo que el cliente acepta por UDP; un poco más de 512 B suele caber en su búfer.
        val limit = maxOf(DnsPacket.ednsSize(p.query), 1232).coerceAtMost(4096)
        try {
            tcpPool.execute {
                val full = queryTcp(server, p.query)
                val usable = full != null && full.size <= limit && !DnsPacket.isTruncated(full) &&
                    u16(full, 0) == u16(p.query, 0) && DnsPacket.questionKey(full) == p.key
                if (usable) {
                    cache?.store(p.query, full!!)
                    put16(full!!, 0, p.originalId)
                    finish(p, full)
                } else {
                    finish(p, truncated)
                }
            }
        } catch (e: RejectedExecutionException) {
            finish(p, truncated)
        }
    }

    private fun queryTcp(server: InetSocketAddress, query: ByteArray): ByteArray? = try {
        Socket().use { s ->
            s.bind(null) // reserva el descriptor: sin él no se puede proteger
            protectTcp(s)
            s.soTimeout = TCP_READ_MS
            s.connect(server, TCP_CONNECT_MS)
            val out = s.getOutputStream()
            out.write(byteArrayOf((query.size shr 8).toByte(), query.size.toByte()))
            out.write(query)
            out.flush()
            val input = DataInputStream(s.getInputStream())
            val n = input.readUnsignedShort()
            if (n < 12) null else ByteArray(n).also { input.readFully(it) }
        }
    } catch (e: Exception) {
        null
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
        tcpPool.shutdownNow()
        pending.clear()
        receiver.interrupt()
    }

    private fun now() = System.nanoTime() / 1_000_000

    private companion object {
        const val MAX_PENDING = 2048
        const val MAX_RESPONSE = 65_535 // el máximo de UDP: una respuesta grande no se corta
        const val STREAK_WINDOW_MS = 10_000L
        const val STREAK_TO_MARK_DOWN = 3
        const val DOWN_FOR_MS = 30_000L
        const val RECENT = 50
        const val REBUILD_AFTER = 5
        const val MAX_BACKOFF_MS = 1_000L
        const val IPV6_BACKOFF_MS = 60_000L
        const val TCP_THREADS = 4
        const val TCP_QUEUE = 32
        const val TCP_CONNECT_MS = 2_000
        const val TCP_READ_MS = 3_000

        fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

        fun put16(b: ByteArray, o: Int, v: Int) {
            b[o] = (v shr 8).toByte()
            b[o + 1] = v.toByte()
        }
    }
}
