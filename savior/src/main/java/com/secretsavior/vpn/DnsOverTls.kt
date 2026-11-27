package com.secretsavior.vpn

import java.io.Closeable
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * DNS sobre TLS (RFC 7858) como transporte de reserva, para redes donde el UDP/53 está bloqueado o
 * interceptado (el reenviador se atasca aunque el teléfono tenga datos). Sólo a los resolutores con
 * filtro familiar de siempre: nunca al DNS de la red, que sería saltarse el filtro.
 *
 * [DotFraming] (el formato de los mensajes) es lógica pura y se prueba; [TlsDotTransport] es la parte
 * fina con sockets: la conexión se inyecta para poder probarla sin TLS.
 */
interface DotTransport : Closeable {
    /** Servidores de los que pueden llegar respuestas. */
    val servers: List<InetSocketAddress>

    /** Encola la consulta (con su id ya puesto). false si no se pudo; nunca bloquea al que llama. */
    fun send(query: ByteArray): Boolean

    /** Cierra la conexión sin cerrar el transporte (sale el modo DoT). */
    fun disconnect()
}

object DotFraming {
    /** Longitud de 2 bytes y el mensaje (RFC 1035 §4.2.2). */
    fun frame(msg: ByteArray): ByteArray {
        require(msg.size in 1..0xFFFF)
        val out = ByteArray(msg.size + 2)
        out[0] = (msg.size shr 8).toByte()
        out[1] = msg.size.toByte()
        System.arraycopy(msg, 0, out, 2, msg.size)
        return out
    }

    /**
     * Reensambla mensajes de un flujo que llega en trozos cualquiera: [feed] devuelve los que se
     * completaron. Un mensaje de longitud 0 o menor que una cabecera DNS es un fallo del flujo
     * (lanza): no hay forma de resincronizar.
     */
    class Deframer(private val maxBuffered: Int = 1 shl 17) {
        private var buf = ByteArray(0)
        private var len = 0

        fun feed(data: ByteArray, off: Int = 0, n: Int = data.size): List<ByteArray> {
            if (len + n > maxBuffered) throw IOException("DoT: búfer desbordado")
            if (len + n > buf.size) buf = buf.copyOf(maxOf(len + n, buf.size * 2).coerceAtMost(maxBuffered))
            System.arraycopy(data, off, buf, len, n)
            len += n
            val out = ArrayList<ByteArray>(2)
            var pos = 0
            while (len - pos >= 2) {
                val size = ((buf[pos].toInt() and 0xFF) shl 8) or (buf[pos + 1].toInt() and 0xFF)
                if (size < 12) throw IOException("DoT: mensaje de $size bytes")
                if (len - pos - 2 < size) break
                out += buf.copyOfRange(pos + 2, pos + 2 + size)
                pos += 2 + size
            }
            if (pos > 0) {
                System.arraycopy(buf, pos, buf, 0, len - pos)
                len -= pos
            }
            return out
        }
    }
}

/**
 * Una conexión TLS persistente y segmentada: las consultas salen una tras otra sin esperar la
 * respuesta y las respuestas llegan en cualquier orden (se casan por el id que ya pone el
 * reenviador). Un hilo escribe y otro lee; nada bloquea al que llama a [send].
 *
 * [connect] crea el socket ya conectado y verificado; la versión de verdad es [tls].
 */
class TlsDotTransport(
    private val targets: List<Target>,
    private val connect: (Target) -> Socket,
    private val onMessage: (ByteArray, InetSocketAddress) -> Unit,
    private val onThreadStart: () -> Unit = {},
    private val idleMs: Long = IDLE_MS,
    private val retryMs: Long = RETRY_MS,
) : DotTransport {

    class Target(val address: InetSocketAddress, val host: String)

    override val servers: List<InetSocketAddress> = targets.map { it.address }

    private class Conn(val socket: Socket, val target: Target)

    private val queue = LinkedBlockingQueue<ByteArray>(QUEUE)

    @Volatile
    private var conn: Conn? = null

    @Volatile
    private var closed = false

    /** Dónde se conectó la última vez con éxito: se empieza por ahí. */
    @Volatile
    private var preferred = 0

    @Volatile
    private var worker: Thread? = null

    @Volatile
    private var retryAt = 0L

    override fun send(query: ByteArray): Boolean {
        if (closed || query.size < 12) return false
        if (!queue.offer(DotFraming.frame(query))) return false
        if (worker == null) startWorker()
        return true
    }

    @Synchronized
    private fun startWorker() {
        if (worker != null || closed) return
        worker = Thread({
            onThreadStart()
            try {
                writeLoop()
            } catch (t: Throwable) {
                dropConnection()
            }
            worker = null // si murió con el transporte abierto, el siguiente envío lo relanza
        }, "savior-dot").apply { isDaemon = true; start() }
    }

    private fun writeLoop() {
        while (!closed) {
            val frame = try {
                queue.poll(idleMs, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                break
            }
            if (frame == null) { // nadie ha preguntado en un rato: no se mantiene el socket
                dropConnection()
                continue
            }
            try {
                val c = conn ?: openConnection()
                if (c == null) {
                    queue.clear() // sin conexión: esas consultas caducan y el reenviador las reintenta por UDP
                    continue
                }
                try {
                    val out = c.socket.getOutputStream()
                    out.write(frame)
                    out.flush()
                } catch (e: IOException) {
                    dropConnection()
                }
            } catch (e: Throwable) {
                dropConnection() // el hilo no puede morir
            }
        }
        dropConnection()
    }

    private fun openConnection(): Conn? {
        val now = System.nanoTime() / 1_000_000
        if (now < retryAt) return null
        for (k in targets.indices) {
            val t = targets[(preferred + k) % targets.size]
            val s = try {
                connect(t)
            } catch (e: Throwable) {
                continue
            }
            preferred = (preferred + k) % targets.size
            val c = Conn(s, t)
            conn = c
            Thread({
                onThreadStart()
                try {
                    readLoop(c)
                } catch (t: Throwable) {
                    if (conn === c) dropConnection()
                }
            }, "savior-dot-rx").apply { isDaemon = true; start() }
            return c
        }
        retryAt = now + retryMs // todos fallaron: no se machaca la red con intentos
        return null
    }

    private fun readLoop(c: Conn) {
        val deframer = DotFraming.Deframer()
        val buf = ByteArray(4096)
        try {
            val input = c.socket.getInputStream()
            while (!closed && conn === c) {
                val n = input.read(buf)
                if (n < 0) break
                for (m in deframer.feed(buf, 0, n)) {
                    try {
                        onMessage(m, c.target.address)
                    } catch (e: Throwable) {
                        // una respuesta que falla no tumba la conexión
                    }
                }
            }
        } catch (e: Throwable) {
            // cerrada o rota: se reabre con la siguiente consulta
        }
        if (conn === c) dropConnection()
    }

    private fun dropConnection() {
        val c = conn ?: return
        conn = null
        try {
            c.socket.close()
        } catch (e: IOException) {
            // ya estaba cerrado
        }
    }

    override fun disconnect() {
        queue.clear()
        dropConnection()
    }

    override fun close() {
        closed = true
        queue.clear()
        dropConnection()
        worker?.interrupt()
    }

    companion object {
        const val QUEUE = 64
        const val IDLE_MS = 60_000L
        const val RETRY_MS = 5_000L
        const val CONNECT_MS = 2_500
        const val HANDSHAKE_MS = 3_000

        /**
         * La conexión de verdad: socket protegido (fuera del túnel), TLS con el nombre del servidor y
         * el nombre del certificado comprobado con el verificador de la plataforma. Sin comprobar
         * el nombre no se usa: cualquiera en la ruta podría contestar.
         */
        fun tls(protect: (Socket) -> Unit): (Target) -> Socket = { t ->
            val plain = Socket()
            try {
                plain.bind(null) // reserva el descriptor: sin él no se puede proteger
                protect(plain)
                plain.tcpNoDelay = true
                plain.keepAlive = true
                plain.connect(t.address, CONNECT_MS)
                plain.soTimeout = HANDSHAKE_MS
                val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
                val ssl = factory.createSocket(plain, t.host, t.address.port, true) as SSLSocket
                ssl.startHandshake()
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(t.host, ssl.session)) {
                    ssl.close()
                    throw SSLPeerUnverifiedException("DoT: el certificado no es de ${t.host}")
                }
                ssl.soTimeout = 0 // lectura bloqueante: el cierre por inactividad lo hace el escritor
                ssl
            } catch (e: Exception) {
                try {
                    plain.close()
                } catch (ignored: IOException) {
                }
                throw e
            }
        }
    }
}
