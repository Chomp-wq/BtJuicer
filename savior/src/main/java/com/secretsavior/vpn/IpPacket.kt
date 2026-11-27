package com.secretsavior.vpn

/** Cabeceras IPv4/UDP/TCP justas para contestar por el túnel. */
object IpPacket {

    const val PROTO_TCP = 6
    const val PROTO_UDP = 17

    /** Un datagrama UDP de vuelta: origen y destino intercambiados. */
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

    /**
     * Rechazo inmediato de una conexión TCP al "servidor" DNS. Android prueba
     * DNS-sobre-TLS (puerto 853) contra el DNS de la VPN; con un RST cae al
     * DNS normal al instante en vez de esperar un tiempo de espera.
     */
    fun tcpReset(request: ByteArray, len: Int, ihl: Int): ByteArray? {
        if (len < ihl + 20) return null
        val flags = request[ihl + 13].toInt() and 0xFF
        if (flags and 0x04 != 0) return null // ya es un RST: no se contesta a un RST
        val seq = u32(request, ihl + 4)
        val ack = u32(request, ihl + 8)
        val dataOffset = ((request[ihl + 12].toInt() and 0xF0) shr 4) * 4
        val payload = (len - ihl - dataOffset).coerceAtLeast(0)
        val syn = if (flags and 0x02 != 0) 1 else 0
        val fin = if (flags and 0x01 != 0) 1 else 0

        val out = ByteArray(40)
        ipHeader(out, 40, PROTO_TCP, request, 12, 16)
        out[20] = request[ihl + 2]; out[21] = request[ihl + 3]
        out[22] = request[ihl]; out[23] = request[ihl + 1]
        if (flags and 0x10 != 0) {
            put32(out, 24, ack)       // seq = el ack que esperaban
            out[33] = 0x04            // RST
        } else {
            put32(out, 24, 0)
            put32(out, 28, seq + payload + syn + fin)
            out[33] = 0x14            // RST + ACK
        }
        out[32] = 0x50                // 5 palabras de cabecera
        // checksum TCP con pseudo-cabecera
        val pseudo = ByteArray(12 + 20)
        System.arraycopy(out, 12, pseudo, 0, 8)
        pseudo[9] = PROTO_TCP.toByte()
        put16(pseudo, 10, 20)
        System.arraycopy(out, 20, pseudo, 12, 20)
        put16(out, 36, checksum(pseudo, 0, pseudo.size))
        return out
    }

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

    fun checksum(b: ByteArray, off: Int, len: Int): Int {
        var sum = 0L
        var i = off
        while (i + 1 < off + len) {
            sum += ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
            i += 2
        }
        if (i < off + len) sum += (b[i].toInt() and 0xFF) shl 8
        while (sum shr 16 != 0L) sum = (sum and 0xFFFF) + (sum shr 16)
        return (sum.inv() and 0xFFFF).toInt()
    }

    private fun put16(b: ByteArray, o: Int, v: Int) {
        b[o] = (v shr 8).toByte(); b[o + 1] = v.toByte()
    }

    private fun put32(b: ByteArray, o: Int, v: Long) {
        b[o] = (v shr 24).toByte(); b[o + 1] = (v shr 16).toByte()
        b[o + 2] = (v shr 8).toByte(); b[o + 3] = v.toByte()
    }

    private fun u32(b: ByteArray, o: Int): Long =
        ((b[o].toLong() and 0xFF) shl 24) or ((b[o + 1].toLong() and 0xFF) shl 16) or
            ((b[o + 2].toLong() and 0xFF) shl 8) or (b[o + 3].toLong() and 0xFF)
}
