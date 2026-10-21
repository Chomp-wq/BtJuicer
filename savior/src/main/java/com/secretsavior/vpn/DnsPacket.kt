package com.secretsavior.vpn

/** Lo mínimo de DNS (RFC 1035) para leer la pregunta y fabricar respuestas. */
object DnsPacket {

    const val TYPE_A = 1
    const val TYPE_AAAA = 28

    private const val RCODE_SERVFAIL = 2

    class Question(val name: String, val type: Int, val end: Int)

    /** Lee la primera pregunta de una consulta, o null si el paquete no es una consulta válida. */
    fun parseQuestion(msg: ByteArray, len: Int = msg.size): Question? {
        if (len < 17) return null
        val flags = u16(msg, 2)
        if (flags and 0x8000 != 0) return null // una respuesta, no una consulta
        if (u16(msg, 4) < 1) return null
        var pos = 12
        val name = StringBuilder()
        while (true) {
            if (pos >= len) return null
            val l = msg[pos].toInt() and 0xFF
            if (l == 0) {
                pos++
                break
            }
            if (l and 0xC0 != 0) return null // las preguntas no llevan compresión
            if (pos + 1 + l > len) return null
            if (name.isNotEmpty()) name.append('.')
            for (i in 0 until l) name.append((msg[pos + 1 + i].toInt() and 0xFF).toChar())
            pos += 1 + l
        }
        if (pos + 4 > len) return null
        return Question(name.toString(), u16(msg, pos), pos + 4)
    }

    /**
     * Respuesta de bloqueo: 0.0.0.0 para A, :: para AAAA y "no hay registros"
     * para el resto. Un NXDOMAIN empujaría a algunos navegadores a probar otro
     * resolutor; una dirección que no lleva a ninguna parte, no.
     */
    fun blocked(query: ByteArray, q: Question): ByteArray {
        val answer = q.type == TYPE_A || q.type == TYPE_AAAA
        val rdata = if (q.type == TYPE_A) 4 else 16
        val out = ByteArray(q.end + if (answer) 12 + rdata else 0)
        System.arraycopy(query, 0, out, 0, q.end)
        out[2] = 0x81.toByte() // QR, RD
        out[3] = 0x80.toByte() // RA, RCODE 0
        out[6] = 0
        out[7] = if (answer) 1 else 0
        out[8] = 0; out[9] = 0; out[10] = 0; out[11] = 0
        if (answer) {
            var p = q.end
            out[p++] = 0xC0.toByte(); out[p++] = 0x0C // puntero al nombre de la pregunta
            out[p++] = 0; out[p++] = q.type.toByte()
            out[p++] = 0; out[p++] = 1                // clase IN
            out[p++] = 0; out[p++] = 0; out[p++] = 0; out[p++] = 60 // TTL
            out[p++] = 0; out[p] = rdata.toByte()     // RDATA a ceros
        }
        return out
    }

    /** Para cuando ningún resolutor contesta: un error claro es mejor que un silencio de 30 s. */
    fun servfail(query: ByteArray, q: Question): ByteArray {
        val out = query.copyOf(q.end)
        out[2] = 0x81.toByte()
        out[3] = (0x80 or RCODE_SERVFAIL).toByte()
        for (i in 6..11) out[i] = 0
        return out
    }

    private fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)
}
