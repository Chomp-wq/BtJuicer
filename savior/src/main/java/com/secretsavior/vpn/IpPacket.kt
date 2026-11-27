package com.secretsavior.vpn

/**
 * Cabeceras IPv4/IPv6 y UDP/TCP/ICMP justas para contestar por el túnel. Sin Android.
 *
 * IPv6 se lee sin cabeceras de extensión: si el siguiente protocolo no es directamente UDP, TCP o
 * ICMPv6 el paquete se descarta (no se contesta nada raro). En v6 el checksum de UDP es
 * obligatorio y todos llevan pseudo-cabecera; en v4 el de UDP va a 0 (válido).
 */
object IpPacket {

    const val PROTO_ICMP = 1
    const val PROTO_TCP = 6
    const val PROTO_UDP = 17
    const val PROTO_ICMP6 = 58

    const val FIN = 0x01
    const val SYN = 0x02
    const val RST = 0x04
    const val PSH = 0x08
    const val ACK = 0x10

    /** Lo que se necesita de un paquete leído del túnel; las direcciones se quedan en el búfer. */
    class Parsed(
        val v6: Boolean,
        /** Dónde empieza la carga (UDP/TCP/ICMP): la longitud de la cabecera IP. */
        val l4: Int,
        val l4Len: Int,
        val proto: Int,
    ) {
        val addrLen: Int get() = if (v6) 16 else 4
        val srcOff: Int get() = if (v6) 8 else 12
        val dstOff: Int get() = if (v6) 24 else 16
    }

    /** null si no es IPv4/IPv6 entero, o es un fragmento IPv4 (una consulta DNS no se fragmenta). */
    fun parse(buf: ByteArray, n: Int): Parsed? {
        if (n < 20) return null
        return when ((buf[0].toInt() and 0xF0) shr 4) {
            4 -> {
                val ihl = (buf[0].toInt() and 0x0F) * 4
                if (ihl < 20 || n < ihl) return null
                val total = u16(buf, 2)
                if (total < ihl) return null
                if (u16(buf, 6) and 0x3FFF != 0) return null // MF o desplazamiento
                Parsed(false, ihl, minOf(total, n) - ihl, buf[9].toInt() and 0xFF)
            }
            6 -> {
                if (n < 40) return null
                val end = minOf(40 + u16(buf, 4), n)
                Parsed(true, 40, end - 40, buf[6].toInt() and 0xFF)
            }
            else -> null
        }
    }

    // --- UDP ------------------------------------------------------------------------------

    /** Un datagrama UDP de vuelta (IPv4): origen y destino intercambiados. */
    fun udpReply(request: ByteArray, ihl: Int, payload: ByteArray): ByteArray {
        val total = 20 + 8 + payload.size
        val out = ByteArray(total)
        ipHeader(out, total, PROTO_UDP, request, 12, 16)
        // puertos: los de la petición, al revés
        out[20] = request[ihl + 2]; out[21] = request[ihl + 3]
        out[22] = request[ihl]; out[23] = request[ihl + 1]
        put16(out, 24, 8 + payload.size)
        // checksum UDP a 0: válido en IPv4
        System.arraycopy(payload, 0, out, 28, payload.size)
        return out
    }

    /** Lo mismo para IPv4 o IPv6 según [p]; [request] sólo necesita llegar hasta la cabecera UDP. */
    fun udpReply(request: ByteArray, p: Parsed, payload: ByteArray): ByteArray {
        if (!p.v6) return udpReply(request, p.l4, payload)
        val l4Len = 8 + payload.size
        val out = ByteArray(40 + l4Len)
        header(out, true, request, p.dstOff, request, p.srcOff, PROTO_UDP, l4Len)
        out[40] = request[p.l4 + 2]; out[41] = request[p.l4 + 3]
        out[42] = request[p.l4]; out[43] = request[p.l4 + 1]
        put16(out, 44, l4Len)
        System.arraycopy(payload, 0, out, 48, payload.size)
        var c = l4Checksum(true, request, p.dstOff, request, p.srcOff, PROTO_UDP, out, 40, l4Len)
        if (c == 0) c = 0xFFFF // en UDP un 0 significa "sin checksum", y en v6 no vale
        put16(out, 46, c)
        return out
    }

    // --- TCP ------------------------------------------------------------------------------

    /**
     * Rechazo inmediato de una conexión TCP IPv4 al "servidor" DNS. Android prueba
     * DNS-sobre-TLS (puerto 853) contra el DNS de la VPN; con un RST cae al
     * DNS normal al instante en vez de esperar un tiempo de espera.
     */
    fun tcpReset(request: ByteArray, len: Int, ihl: Int): ByteArray? =
        tcpReset(request, len, Parsed(false, ihl, len - ihl, PROTO_TCP))

    /** RST para un segmento TCP (v4 o v6), con las reglas de la RFC 793: nunca se contesta a un RST. */
    fun tcpReset(request: ByteArray, len: Int, p: Parsed): ByteArray? {
        val t = p.l4
        if (p.l4Len < 20 || len < t + 20) return null
        val flags = request[t + 13].toInt() and 0xFF
        if (flags and RST != 0) return null
        val seq = u32(request, t + 4)
        val ack = u32(request, t + 8)
        val dataOffset = ((request[t + 12].toInt() and 0xF0) shr 4) * 4
        val payload = (p.l4Len - dataOffset).coerceAtLeast(0)
        val syn = if (flags and SYN != 0) 1 else 0
        val fin = if (flags and FIN != 0) 1 else 0
        // sale de donde iba el segmento y vuelve a quien lo mandó
        val src = request.copyOfRange(p.dstOff, p.dstOff + p.addrLen)
        val dst = request.copyOfRange(p.srcOff, p.srcOff + p.addrLen)
        val sport = u16(request, t + 2)
        val dport = u16(request, t)
        return if (flags and ACK != 0) {
            tcp(p.v6, src, dst, sport, dport, ack, 0, RST, 0, null, null, 0, 0) // seq = el ack que esperaban
        } else {
            tcp(p.v6, src, dst, sport, dport, 0, seq + payload + syn + fin, RST or ACK, 0, null, null, 0, 0)
        }
    }

    /**
     * Un segmento TCP completo (IP + TCP). [opts] debe medir múltiplo de 4. Los números de
     * secuencia van como Long y se recortan a 32 bits.
     */
    fun tcp(
        v6: Boolean, src: ByteArray, dst: ByteArray, sport: Int, dport: Int,
        seq: Long, ack: Long, flags: Int, window: Int,
        opts: ByteArray?, payload: ByteArray?, pOff: Int, pLen: Int,
    ): ByteArray {
        val optLen = opts?.size ?: 0
        val l4Len = 20 + optLen + pLen
        val hdr = if (v6) 40 else 20
        val out = ByteArray(hdr + l4Len)
        header(out, v6, src, 0, dst, 0, PROTO_TCP, l4Len)
        val t = hdr
        put16(out, t, sport); put16(out, t + 2, dport)
        put32(out, t + 4, seq); put32(out, t + 8, ack)
        out[t + 12] = ((5 + optLen / 4) shl 4).toByte()
        out[t + 13] = flags.toByte()
        put16(out, t + 14, window)
        if (opts != null) System.arraycopy(opts, 0, out, t + 20, optLen)
        if (payload != null && pLen > 0) System.arraycopy(payload, pOff, out, t + 20 + optLen, pLen)
        put16(out, t + 16, l4Checksum(v6, src, 0, dst, 0, PROTO_TCP, out, t, l4Len))
        return out
    }

    // --- ICMP -----------------------------------------------------------------------------

    /**
     * "Puerto inaccesible" para un UDP que no es DNS (QUIC en el 443, DNS-sobre-QUIC en el 853):
     * la app lo recibe como conexión rechazada y vuelve a TCP/DNS normal al instante, en vez de
     * esperar un tiempo de espera. ICMPv4 tipo 3/código 3; ICMPv6 tipo 1/código 4 (con
     * pseudo-cabecera en el checksum). Cita la cabecera IP y el principio de la carga original.
     */
    fun icmpPortUnreachable(request: ByteArray, len: Int, p: Parsed): ByteArray? {
        if (p.proto != PROTO_UDP || p.l4Len < 8) return null
        val quote = if (p.v6) minOf(len, 128) else minOf(len, p.l4 + 8)
        val l4Len = 8 + quote
        val hdr = if (p.v6) 40 else 20
        val out = ByteArray(hdr + l4Len)
        val proto = if (p.v6) PROTO_ICMP6 else PROTO_ICMP
        header(out, p.v6, request, p.dstOff, request, p.srcOff, proto, l4Len)
        out[hdr] = if (p.v6) 1 else 3
        out[hdr + 1] = if (p.v6) 4 else 3
        System.arraycopy(request, 0, out, hdr + 8, quote)
        put16(out, hdr + 2, icmpChecksum(p.v6, out, hdr, l4Len, request, p))
        return out
    }

    /** Responde al ping (eco) de una dirección capturada: "comprobar internet" haciendo ping debe seguir funcionando. */
    fun icmpEchoReply(request: ByteArray, len: Int, p: Parsed): ByteArray? {
        val want = if (p.v6) PROTO_ICMP6 else PROTO_ICMP
        if (p.proto != want || p.l4Len < 8 || len < p.l4 + p.l4Len) return null
        if ((request[p.l4].toInt() and 0xFF) != (if (p.v6) 128 else 8)) return null
        if (request[p.l4 + 1].toInt() != 0) return null
        val hdr = if (p.v6) 40 else 20
        val out = ByteArray(hdr + p.l4Len)
        header(out, p.v6, request, p.dstOff, request, p.srcOff, want, p.l4Len)
        System.arraycopy(request, p.l4, out, hdr, p.l4Len)
        out[hdr] = if (p.v6) 129.toByte() else 0
        out[hdr + 2] = 0; out[hdr + 3] = 0
        put16(out, hdr + 2, icmpChecksum(p.v6, out, hdr, p.l4Len, request, p))
        return out
    }

    private fun icmpChecksum(v6: Boolean, out: ByteArray, at: Int, len: Int, request: ByteArray, p: Parsed): Int =
        if (v6) l4Checksum(true, request, p.dstOff, request, p.srcOff, PROTO_ICMP6, out, at, len)
        else checksum(out, at, len)

    // --- Cabeceras y checksums ------------------------------------------------------------

    /** Cabecera IPv4 de 20 bytes. [srcAt] y [dstAt] son dónde estaban esas direcciones en la petición. */
    private fun ipHeader(out: ByteArray, total: Int, proto: Int, req: ByteArray, srcAt: Int, dstAt: Int) {
        out[0] = 0x45
        put16(out, 2, total)
        out[6] = 0x40 // DF
        out[8] = 64
        out[9] = proto.toByte()
        // la respuesta sale de donde iba la petición y vuelve a quien la mandó
        System.arraycopy(req, dstAt, out, 12, 4)
        System.arraycopy(req, srcAt, out, 16, 4)
        put16(out, 10, checksum(out, 0, 20))
    }

    /** Cabecera IP (v4 de 20 bytes con su checksum, o v6 de 40) con el origen y el destino dados. */
    private fun header(
        out: ByteArray, v6: Boolean, src: ByteArray, srcOff: Int, dst: ByteArray, dstOff: Int, proto: Int, l4Len: Int,
    ) {
        if (v6) {
            out[0] = 0x60
            put16(out, 4, l4Len)
            out[6] = proto.toByte()
            out[7] = 64
            System.arraycopy(src, srcOff, out, 8, 16)
            System.arraycopy(dst, dstOff, out, 24, 16)
        } else {
            out[0] = 0x45
            put16(out, 2, 20 + l4Len)
            out[6] = 0x40 // DF
            out[8] = 64
            out[9] = proto.toByte()
            System.arraycopy(src, srcOff, out, 12, 4)
            System.arraycopy(dst, dstOff, out, 16, 4)
            put16(out, 10, checksum(out, 0, 20))
        }
    }

    fun checksum(b: ByteArray, off: Int, len: Int): Int = fold(sum(b, off, len, 0))

    /**
     * Checksum de un segmento UDP/TCP/ICMPv6 con su pseudo-cabecera (direcciones, longitud, protocolo).
     * Con el campo de checksum a 0 da el valor que hay que poner; sobre un segmento ya completo, 0.
     */
    fun l4Checksum(
        v6: Boolean, src: ByteArray, srcOff: Int, dst: ByteArray, dstOff: Int, proto: Int,
        seg: ByteArray, off: Int, len: Int,
    ): Int {
        val al = if (v6) 16 else 4
        var s = sum(src, srcOff, al, 0)
        s = sum(dst, dstOff, al, s)
        s += len.toLong() + proto
        return fold(sum(seg, off, len, s))
    }

    private fun sum(b: ByteArray, off: Int, len: Int, init: Long): Long {
        var s = init
        var i = off
        val end = off + len
        while (i + 1 < end) {
            s += ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
            i += 2
        }
        if (i < end) s += (b[i].toInt() and 0xFF) shl 8
        return s
    }

    private fun fold(sum: Long): Int {
        var s = sum
        while (s shr 16 != 0L) s = (s and 0xFFFF) + (s shr 16)
        return (s.inv() and 0xFFFF).toInt()
    }

    fun u16(b: ByteArray, o: Int): Int = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

    fun u32(b: ByteArray, o: Int): Long =
        ((b[o].toLong() and 0xFF) shl 24) or ((b[o + 1].toLong() and 0xFF) shl 16) or
            ((b[o + 2].toLong() and 0xFF) shl 8) or (b[o + 3].toLong() and 0xFF)

    private fun put16(b: ByteArray, o: Int, v: Int) {
        b[o] = (v shr 8).toByte(); b[o + 1] = v.toByte()
    }

    private fun put32(b: ByteArray, o: Int, v: Long) {
        b[o] = (v shr 24).toByte(); b[o + 1] = (v shr 16).toByte()
        b[o + 2] = (v shr 8).toByte(); b[o + 3] = v.toByte()
    }
}
