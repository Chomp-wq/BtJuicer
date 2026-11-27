package com.secretsavior.vpn

import java.util.concurrent.ThreadLocalRandom

/**
 * Servidor DNS-sobre-TCP mínimo para el túnel (RFC 1035 §4.2.2: cada mensaje lleva delante su
 * longitud en 2 bytes). Muchas apps «comprueban internet» abriendo 8.8.8.8:53 por TCP; un RST
 * ahí les haría creer que no hay red. Sin Android: recibe segmentos ya leídos del túnel y
 * entrega paquetes IP por [send].
 *
 * Es un TCP de juguete a propósito, porque el túnel es local y no pierde ni reordena:
 * - No se retransmite nada nuestro ni se respeta la ventana del cliente (una respuesta DNS
 *   son pocos KB); no hay temporizadores por conexión, sólo un barrido que sólo corre mientras
 *   haya conexiones.
 * - Datos repetidos o solapados se vuelven a confirmar y se ignoran; los que dejan un hueco se
 *   descartan con un ACK repetido (el cliente reenvía).
 * - Un segmento de una conexión que no existe recibe RST; un fallo inesperado en un paquete
 *   también acaba en RST para esa conexión y nunca sube al lector del túnel.
 * - Máximo [MAX_CONNS] conexiones (se expulsa la más antigua) y [IDLE_MS] de inactividad.
 *
 * Hilos: el lector del túnel llama a [onPacket]; las respuestas llegan desde el hilo del
 * reenviador. Todo el estado va bajo un cerrojo; la consulta al DNS se lanza fuera de él.
 */
class TcpDns(
    private val send: (ByteArray) -> Unit,
    /** Resuelve un mensaje DNS (sin el prefijo de longitud); [done] recibe la respuesta o null (error). */
    private val resolve: (query: ByteArray, done: (ByteArray?) -> Unit) -> Unit,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val newIsn: () -> Int = { ThreadLocalRandom.current().nextInt() },
    /** Pide que se ejecute la tarea dentro de [delayMs]; sólo se usa mientras haya conexiones. */
    private val schedule: (delayMs: Long, task: Runnable) -> Unit = { _, _ -> },
) {

    private class Key(val b: ByteArray) {
        private val hash = b.contentHashCode()
        override fun hashCode() = hash
        override fun equals(other: Any?) = other is Key && other.b.contentEquals(b)
    }

    private class Conn(
        val key: Key,
        val v6: Boolean,
        val client: ByteArray,
        val server: ByteArray,
        val cport: Int,
        val sport: Int,
        val clientIsn: Long,
        val isn: Long,
        val mss: Int,
        var last: Long,
    ) {
        var established = false

        /** Siguiente número de secuencia que se espera del cliente. */
        var rcvNxt = (clientIsn + 1) and M

        /** Siguiente número de secuencia propio. */
        var sndNxt = (isn + 1) and M
        var buf = ByteArray(0)
        var bufLen = 0

        /** Consultas lanzadas cuya respuesta aún no se ha enviado. */
        var pending = 0
        var finReceived = false
    }

    private class Work(val conn: Conn, val msgs: List<ByteArray>)

    private val lock = Any()
    private val conns = HashMap<Key, Conn>()
    private var sweepScheduled = false

    private val sweepTask = object : Runnable {
        override fun run() {
            synchronized(lock) {
                sweepLocked(clock())
                if (conns.isEmpty()) sweepScheduled = false else schedule(SWEEP_MS, this)
            }
        }
    }

    val size: Int get() = synchronized(lock) { conns.size }

    /** Cierra (FIN) las conexiones que llevan más de [IDLE_MS] sin actividad. */
    fun sweep() = synchronized(lock) { sweepLocked(clock()) }

    /** Un segmento TCP dirigido a una dirección que contestamos; [p] ya es TCP. Nunca lanza. */
    fun onPacket(buf: ByteArray, n: Int, p: IpPacket.Parsed) {
        val work = try {
            synchronized(lock) { step(buf, n, p) }
        } catch (e: Exception) {
            synchronized(lock) { conns.remove(keyOf(buf, p)) }
            try {
                IpPacket.tcpReset(buf, n, p)?.let(send)
            } catch (e2: Exception) {
                // sin más: el paquete se pierde
            }
            return
        }
        if (work != null) {
            for (m in work.msgs) {
                try {
                    resolve(m) { r -> onResponse(work.conn, r) }
                } catch (e: Exception) {
                    onResponse(work.conn, null)
                }
            }
        }
    }

    private fun step(buf: ByteArray, n: Int, p: IpPacket.Parsed): Work? {
        val t = p.l4
        if (p.l4Len < 20 || n < t + 20) return null
        val off = ((buf[t + 12].toInt() and 0xF0) shr 4) * 4
        if (off < 20 || off > p.l4Len) return null
        val flags = buf[t + 13].toInt() and 0xFF
        val seq = IpPacket.u32(buf, t + 4)
        val plen = p.l4Len - off
        val key = keyOf(buf, p)
        val now = clock()
        val c = conns[key]

        if (flags and IpPacket.RST != 0) {
            if (c != null) conns.remove(key)
            return null
        }
        if (c == null) {
            if (flags and IpPacket.SYN != 0 && flags and IpPacket.ACK == 0) open(buf, p, key, seq, off, now)
            else IpPacket.tcpReset(buf, n, p)?.let(send)
            return null
        }
        c.last = now

        if (flags and IpPacket.SYN != 0) {
            // SYN repetido: el SYN-ACK se perdió o se retrasó. Cualquier otro SYN es ruido: un ACK.
            if (!c.established && flags and IpPacket.ACK == 0 && seq == c.clientIsn) synAck(c) else ack(c)
            return null
        }
        if (flags and IpPacket.ACK == 0) return null
        if (!c.established) {
            if (IpPacket.u32(buf, t + 8) != c.sndNxt) {
                conns.remove(key)
                IpPacket.tcpReset(buf, n, p)?.let(send)
                return null
            }
            c.established = true
        }

        val fin = flags and IpPacket.FIN != 0
        if (plen == 0 && !fin) return null // un ACK puro: no se contesta a un ACK

        // Aritmética de 32 bits con vuelta: positivo = el cliente repite algo que ya tenemos.
        val behind = (c.rcvNxt - seq).toInt()
        if (behind < 0) { // hueco: se pide de nuevo lo que falta
            ack(c)
            return null
        }
        var skip = 0
        if (behind > 0) {
            val fresh = plen > behind || (plen == behind && fin && !c.finReceived)
            if (!fresh) { // retransmisión entera
                ack(c)
                return null
            }
            skip = minOf(behind, plen)
        }
        val newLen = plen - skip
        if (newLen > 0) append(c, buf, t + off + skip, newLen)
        c.rcvNxt = (c.rcvNxt + newLen) and M
        if (fin && !c.finReceived) {
            c.finReceived = true
            c.rcvNxt = (c.rcvNxt + 1) and M
        }

        val msgs = extract(c)
        if (msgs == null) { // mensaje imposible: mejor cortar que quedarse esperando
            conns.remove(key)
            IpPacket.tcpReset(buf, n, p)?.let(send)
            return null
        }
        if (msgs.isEmpty() && c.finReceived && c.pending == 0) {
            segment(c, IpPacket.FIN or IpPacket.ACK, null, 0, 0)
            conns.remove(key)
            return null
        }
        ack(c)
        return if (msgs.isEmpty()) null else Work(c, msgs)
    }

    private fun open(buf: ByteArray, p: IpPacket.Parsed, key: Key, seq: Long, off: Int, now: Long) {
        if (conns.size >= MAX_CONNS) evictOldest()
        val al = p.addrLen
        val isn = newIsn().toLong() and M
        val c = Conn(
            key, p.v6,
            client = buf.copyOfRange(p.srcOff, p.srcOff + al),
            server = buf.copyOfRange(p.dstOff, p.dstOff + al),
            cport = IpPacket.u16(buf, p.l4), sport = IpPacket.u16(buf, p.l4 + 2),
            clientIsn = seq, isn = isn, mss = peerMss(buf, p.l4 + 20, p.l4 + off), last = now,
        )
        conns[key] = c
        synAck(c)
        if (!sweepScheduled) {
            sweepScheduled = true
            schedule(SWEEP_MS, sweepTask)
        }
    }

    /** El MSS que anuncia el cliente en su SYN (RFC 793: sin opción, 536), acotado a lo que enviamos. */
    private fun peerMss(b: ByteArray, from: Int, to: Int): Int {
        var i = from
        while (i < to) {
            when (val kind = b[i].toInt() and 0xFF) {
                0 -> break
                1 -> i++
                else -> {
                    if (i + 1 >= to) break
                    val l = b[i + 1].toInt() and 0xFF
                    if (l < 2 || i + l > to) break
                    if (kind == 2 && l == 4) return IpPacket.u16(b, i + 2).coerceIn(MIN_SEG, MAX_SEG)
                    i += l
                }
            }
        }
        return MIN_SEG
    }

    private fun append(c: Conn, b: ByteArray, from: Int, len: Int) {
        if (c.bufLen + len > c.buf.size) c.buf = c.buf.copyOf(maxOf(c.bufLen + len, c.buf.size * 2, 256))
        System.arraycopy(b, from, c.buf, c.bufLen, len)
        c.bufLen += len
    }

    /** Mensajes completos que hay en el búfer, o null si el flujo no es DNS (longitud absurda, demasiado pipeline). */
    private fun extract(c: Conn): List<ByteArray>? {
        var out: ArrayList<ByteArray>? = null
        var pos = 0
        while (c.bufLen - pos >= 2) {
            val len = ((c.buf[pos].toInt() and 0xFF) shl 8) or (c.buf[pos + 1].toInt() and 0xFF)
            if (len < MIN_DNS) return null
            if (c.bufLen - pos < 2 + len) break
            if (c.pending + (out?.size ?: 0) >= MAX_PIPELINE) return null
            if (out == null) out = ArrayList(2)
            out.add(c.buf.copyOfRange(pos + 2, pos + 2 + len))
            pos += 2 + len
        }
        if (pos > 0) {
            System.arraycopy(c.buf, pos, c.buf, 0, c.bufLen - pos)
            c.bufLen -= pos
        }
        if (out != null) c.pending += out.size
        return out ?: emptyList()
    }

    private fun onResponse(c: Conn, response: ByteArray?) {
        synchronized(lock) {
            try {
                if (conns[c.key] !== c) return // se cerró mientras tanto
                c.pending--
                c.last = clock()
                if (response == null || response.size > 0xFFFF) {
                    segment(c, IpPacket.RST or IpPacket.ACK, null, 0, 0)
                    conns.remove(c.key)
                    return
                }
                val framed = ByteArray(2 + response.size)
                framed[0] = (response.size shr 8).toByte(); framed[1] = response.size.toByte()
                System.arraycopy(response, 0, framed, 2, response.size)
                var pos = 0
                while (pos < framed.size) {
                    val n = minOf(c.mss, framed.size - pos)
                    val last = pos + n == framed.size
                    segment(c, IpPacket.ACK or (if (last) IpPacket.PSH else 0), framed, pos, n)
                    c.sndNxt = (c.sndNxt + n) and M
                    pos += n
                }
                if (c.finReceived && c.pending == 0) {
                    segment(c, IpPacket.FIN or IpPacket.ACK, null, 0, 0)
                    conns.remove(c.key)
                }
            } catch (e: Exception) {
                conns.remove(c.key)
            }
        }
    }

    private fun sweepLocked(now: Long) {
        val it = conns.values.iterator()
        while (it.hasNext()) {
            val c = it.next()
            if (now - c.last > IDLE_MS) {
                it.remove()
                try {
                    segment(c, IpPacket.FIN or IpPacket.ACK, null, 0, 0)
                } catch (e: Exception) {
                    // sin más
                }
            }
        }
    }

    private fun evictOldest() {
        val old = conns.values.minByOrNull { it.last } ?: return
        conns.remove(old.key)
        segment(old, IpPacket.RST or IpPacket.ACK, null, 0, 0)
    }

    private fun synAck(c: Conn) {
        // MSS 1400: lo que cabe sin fragmentar en un túnel de MTU 1500 también con IPv6.
        val opts = byteArrayOf(2, 4, (MAX_SEG shr 8).toByte(), MAX_SEG.toByte())
        send(
            IpPacket.tcp(
                c.v6, c.server, c.client, c.sport, c.cport, c.isn, c.rcvNxt,
                IpPacket.SYN or IpPacket.ACK, WINDOW, opts, null, 0, 0,
            ),
        )
    }

    private fun ack(c: Conn) = segment(c, IpPacket.ACK, null, 0, 0)

    private fun segment(c: Conn, flags: Int, payload: ByteArray?, off: Int, len: Int) {
        send(
            IpPacket.tcp(
                c.v6, c.server, c.client, c.sport, c.cport, c.sndNxt, c.rcvNxt, flags, WINDOW, null, payload, off, len,
            ),
        )
    }

    private fun keyOf(buf: ByteArray, p: IpPacket.Parsed): Key {
        val al = p.addrLen
        val b = ByteArray(2 * al + 4)
        System.arraycopy(buf, p.srcOff, b, 0, al)
        System.arraycopy(buf, p.dstOff, b, al, al)
        System.arraycopy(buf, p.l4, b, 2 * al, 4) // puertos origen y destino
        return Key(b)
    }

    companion object {
        const val MAX_CONNS = 256
        const val IDLE_MS = 10_000L
        const val SWEEP_MS = 2_000L
        const val MAX_SEG = 1400
        private const val MIN_SEG = 536
        private const val MIN_DNS = 12 // una cabecera DNS
        private const val MAX_PIPELINE = 64
        private const val WINDOW = 65535
        private const val M = 0xFFFFFFFFL
    }
}
