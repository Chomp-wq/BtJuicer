package com.secretsavior

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/**
 * Verificador de paquetes IP independiente de `IpPacket`: recalcula longitudes y checksums
 * (cabecera IPv4, pseudo-cabecera de UDP/TCP/ICMPv6, ICMPv4) desde cero. Si los constructores
 * y esto se equivocaran igual, no habría forma de enterarse: por eso es otro código.
 */
object PacketCheck {

    fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

    fun u32(b: ByteArray, o: Int): Long = (u16(b, o).toLong() shl 16) or u16(b, o + 2).toLong()

    private fun sum(b: ByteArray, off: Int, len: Int, init: Long = 0): Long {
        var s = init
        var i = 0
        while (i < len) {
            val hi = b[off + i].toInt() and 0xFF
            val lo = if (i + 1 < len) b[off + i + 1].toInt() and 0xFF else 0
            s += (hi shl 8) or lo
            i += 2
        }
        return s
    }

    private fun folded(s0: Long): Int {
        var s = s0
        while (s ushr 16 != 0L) s = (s and 0xFFFF) + (s ushr 16)
        return s.toInt()
    }

    /** El valor que hay que poner en el campo de checksum de [seg] (con ese campo a 0). */
    fun l4Checksum(src: ByteArray, dst: ByteArray, proto: Int, seg: ByteArray): Int {
        var s = sum(src, 0, src.size) + sum(dst, 0, dst.size)
        s += seg.size.toLong() + proto
        s = sum(seg, 0, seg.size, s)
        return folded(s).inv() and 0xFFFF
    }

    class Info(val v6: Boolean, val proto: Int, val src: ByteArray, val dst: ByteArray, val l4: Int, val l4Len: Int)

    /** Comprueba el paquete entero y devuelve sus partes. Falla el test si algo no cuadra. */
    fun verify(p: ByteArray): Info {
        val v6 = (p[0].toInt() ushr 4) == 6
        val info: Info
        if (!v6) {
            assertEquals("versión", 4, p[0].toInt() ushr 4)
            assertEquals("IHL", 5, p[0].toInt() and 0x0F)
            assertEquals("longitud total", p.size, u16(p, 2))
            assertEquals("checksum de la cabecera IPv4", 0xFFFF, folded(sum(p, 0, 20)))
            info = Info(false, p[9].toInt() and 0xFF, p.copyOfRange(12, 16), p.copyOfRange(16, 20), 20, p.size - 20)
        } else {
            assertEquals("longitud de carga", p.size - 40, u16(p, 4))
            info = Info(true, p[6].toInt() and 0xFF, p.copyOfRange(8, 24), p.copyOfRange(24, 40), 40, p.size - 40)
        }
        val seg = p.copyOfRange(info.l4, p.size)
        when (info.proto) {
            6, 58 -> assertEquals("checksum de la capa 4", 0, l4Verify(info, seg))
            17 -> {
                val c = u16(seg, 6)
                if (v6) assertTrue("el checksum UDP es obligatorio en IPv6", c != 0)
                if (c != 0) assertEquals("checksum UDP", 0, l4Verify(info, seg))
                assertEquals("longitud UDP", seg.size, u16(seg, 4))
            }
            1 -> assertEquals("checksum ICMPv4", 0xFFFF, folded(sum(seg, 0, seg.size)))
            else -> throw AssertionError("protocolo inesperado ${info.proto}")
        }
        return info
    }

    /** 0 si el segmento (con su checksum puesto) es válido. */
    private fun l4Verify(i: Info, seg: ByteArray): Int {
        var s = sum(i.src, 0, i.src.size) + sum(i.dst, 0, i.dst.size)
        s += seg.size.toLong() + i.proto
        s = sum(seg, 0, seg.size, s)
        return folded(s).inv() and 0xFFFF
    }

    // --- Paquetes de petición, construidos a mano ------------------------------------------

    fun v4(proto: Int, src: ByteArray, dst: ByteArray, l4: ByteArray): ByteArray {
        val p = ByteArray(20 + l4.size)
        p[0] = 0x45; p[8] = 64; p[9] = proto.toByte()
        p[2] = ((20 + l4.size) shr 8).toByte(); p[3] = (20 + l4.size).toByte()
        System.arraycopy(src, 0, p, 12, 4); System.arraycopy(dst, 0, p, 16, 4)
        val c = folded(sum(p, 0, 20)).inv() and 0xFFFF
        p[10] = (c shr 8).toByte(); p[11] = c.toByte()
        System.arraycopy(l4, 0, p, 20, l4.size)
        return p
    }

    fun v6(proto: Int, src: ByteArray, dst: ByteArray, l4: ByteArray): ByteArray {
        val p = ByteArray(40 + l4.size)
        p[0] = 0x60; p[4] = (l4.size shr 8).toByte(); p[5] = l4.size.toByte()
        p[6] = proto.toByte(); p[7] = 64
        System.arraycopy(src, 0, p, 8, 16); System.arraycopy(dst, 0, p, 24, 16)
        System.arraycopy(l4, 0, p, 40, l4.size)
        return p
    }

    fun udp(sport: Int, dport: Int, payload: ByteArray): ByteArray {
        val u = ByteArray(8 + payload.size)
        u[0] = (sport shr 8).toByte(); u[1] = sport.toByte()
        u[2] = (dport shr 8).toByte(); u[3] = dport.toByte()
        u[4] = (u.size shr 8).toByte(); u[5] = u.size.toByte()
        System.arraycopy(payload, 0, u, 8, payload.size)
        return u
    }

    /** Un datagrama UDP con checksum bueno si es v6, a 0 si es v4. */
    fun udpPacket(v6: Boolean, src: ByteArray, dst: ByteArray, sport: Int, dport: Int, payload: ByteArray): ByteArray {
        val u = udp(sport, dport, payload)
        if (v6) {
            val c = l4Checksum(src, dst, 17, u).let { if (it == 0) 0xFFFF else it }
            u[6] = (c shr 8).toByte(); u[7] = c.toByte()
        }
        return if (v6) v6(17, src, dst, u) else v4(17, src, dst, u)
    }

    val V4_CLIENT = bytes(10, 255, 255, 2)
    val V4_8888 = bytes(8, 8, 8, 8)
    val V6_CLIENT = ByteArray(16).also { it[0] = 0xFD.toByte(); it[1] = 0x53; it[15] = 2 }
    val V6_GOOGLE = ByteArray(16).also {
        it[0] = 0x20; it[1] = 0x01; it[2] = 0x48; it[3] = 0x60; it[4] = 0x48; it[5] = 0x60; it[14] = 0x88.toByte(); it[15] = 0x88.toByte()
    }
}
