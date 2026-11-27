package com.secretsavior

import com.secretsavior.PacketCheck.V4_8888
import com.secretsavior.PacketCheck.V4_CLIENT
import com.secretsavior.PacketCheck.V6_CLIENT
import com.secretsavior.PacketCheck.V6_GOOGLE
import com.secretsavior.PacketCheck.bytes
import com.secretsavior.PacketCheck.u16
import com.secretsavior.PacketCheck.u32
import com.secretsavior.vpn.IpPacket
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IpPacketTest {

    private val payload = ByteArray(37) { (it * 7 + 1).toByte() } // longitud impar a propósito

    private fun parsed(p: ByteArray) = IpPacket.parse(p, p.size)!!

    // --- checksum -------------------------------------------------------------------------

    @Test
    fun checksumMatchesAKnownIpv4HeaderVector() {
        // Ejemplo clásico de Wikipedia: la cabecera con el checksum a 0 da 0xB861.
        val h = bytes(0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0, 0, 0xC0, 0xA8, 0, 1, 0xC0, 0xA8, 0, 0xC7)
        assertEquals(0xB861, IpPacket.checksum(h, 0, 20))
    }

    // --- parse ----------------------------------------------------------------------------

    @Test
    fun parseReadsV4AndV6AndRejectsFragmentsAndJunk() {
        val v4 = PacketCheck.udpPacket(false, V4_CLIENT, V4_8888, 40000, 53, payload)
        val p4 = parsed(v4)
        assertEquals(false, p4.v6); assertEquals(20, p4.l4); assertEquals(8 + payload.size, p4.l4Len)
        assertEquals(IpPacket.PROTO_UDP, p4.proto)

        val v6 = PacketCheck.udpPacket(true, V6_CLIENT, V6_GOOGLE, 40000, 53, payload)
        val p6 = parsed(v6)
        assertEquals(true, p6.v6); assertEquals(40, p6.l4); assertEquals(8 + payload.size, p6.l4Len)

        val frag = v4.copyOf().also { it[6] = 0x20 } // MF
        assertNull(IpPacket.parse(frag, frag.size))
        val off = v4.copyOf().also { it[7] = 5 } // desplazamiento
        assertNull(IpPacket.parse(off, off.size))
        assertNull(IpPacket.parse(ByteArray(19), 19))
        assertNull(IpPacket.parse(v6, 39))
        assertNull(IpPacket.parse(bytes(0x15) + ByteArray(30), 31)) // versión 1
    }

    // --- UDP ------------------------------------------------------------------------------

    @Test
    fun udpReplyV4SwapsEndpointsAndKeepsPayload() {
        val req = PacketCheck.udpPacket(false, V4_CLIENT, V4_8888, 40000, 53, payload)
        val rep = IpPacket.udpReply(req, parsed(req), payload.reversedArray())
        val i = PacketCheck.verify(rep)
        assertArrayEquals(V4_8888, i.src); assertArrayEquals(V4_CLIENT, i.dst)
        assertEquals(53, u16(rep, 20)); assertEquals(40000, u16(rep, 22))
        assertArrayEquals(payload.reversedArray(), rep.copyOfRange(28, rep.size))
        // y es byte a byte lo que hacía la versión sólo-IPv4
        assertArrayEquals(IpPacket.udpReply(req, 20, payload.reversedArray()), rep)
    }

    @Test
    fun udpReplyV6HasAValidMandatoryChecksum() {
        val req = PacketCheck.udpPacket(true, V6_CLIENT, V6_GOOGLE, 40000, 53, payload)
        val rep = IpPacket.udpReply(req, parsed(req), payload.reversedArray())
        val i = PacketCheck.verify(rep) // comprueba el checksum con pseudo-cabecera
        assertArrayEquals(V6_GOOGLE, i.src); assertArrayEquals(V6_CLIENT, i.dst)
        assertEquals(53, u16(rep, 40)); assertEquals(40000, u16(rep, 42))
        assertEquals(8 + payload.size, u16(rep, 44))
        assertArrayEquals(payload.reversedArray(), rep.copyOfRange(48, rep.size))
    }

    @Test
    fun udpReplyV6EvenAndEmptyPayloads() {
        val req = PacketCheck.udpPacket(true, V6_CLIENT, V6_GOOGLE, 1234, 53, payload)
        for (len in listOf(0, 1, 2, 511, 512, 1200)) {
            PacketCheck.verify(IpPacket.udpReply(req, parsed(req), ByteArray(len) { (it * 31).toByte() }))
        }
    }

    // --- TCP ------------------------------------------------------------------------------

    private fun clientTcp(v6: Boolean, seq: Long, ack: Long, flags: Int, data: ByteArray? = null): ByteArray {
        val src = if (v6) V6_CLIENT else V4_CLIENT
        val dst = if (v6) V6_GOOGLE else V4_8888
        return IpPacket.tcp(v6, src, dst, 50000, 53, seq, ack, flags, 1000, null, data, 0, data?.size ?: 0)
    }

    @Test
    fun tcpBuilderProducesValidSegmentsOnBothFamilies() {
        for (v6 in listOf(false, true)) {
            val seg = clientTcp(v6, 0xFFFFFFF0L, 77, IpPacket.ACK or IpPacket.PSH, payload)
            val i = PacketCheck.verify(seg)
            assertEquals(v6, i.v6)
            assertEquals(0xFFFFFFF0L, u32(seg, i.l4 + 4))
            assertEquals(77L, u32(seg, i.l4 + 8))
            assertArrayEquals(payload, seg.copyOfRange(i.l4 + 20, seg.size))
        }
    }

    @Test
    fun tcpResetToAnAckUsesTheirAckAsSequence() {
        for (v6 in listOf(false, true)) {
            val req = clientTcp(v6, 1000, 5000, IpPacket.ACK)
            val rst = IpPacket.tcpReset(req, req.size, parsed(req))!!
            val i = PacketCheck.verify(rst)
            assertEquals(IpPacket.RST, rst[i.l4 + 13].toInt() and 0xFF)
            assertEquals(5000L, u32(rst, i.l4 + 4))
            assertEquals(50000, u16(rst, i.l4 + 2)); assertEquals(53, u16(rst, i.l4))
            assertArrayEquals(if (v6) V6_GOOGLE else V4_8888, i.src)
        }
    }

    @Test
    fun tcpResetToASynAcksItsSequencePlusOne() {
        for (v6 in listOf(false, true)) {
            val req = clientTcp(v6, 0xFFFFFFFFL, 0, IpPacket.SYN) // la secuencia da la vuelta
            val rst = IpPacket.tcpReset(req, req.size, parsed(req))!!
            val i = PacketCheck.verify(rst)
            assertEquals(IpPacket.RST or IpPacket.ACK, rst[i.l4 + 13].toInt() and 0xFF)
            assertEquals(0L, u32(rst, i.l4 + 4))
            assertEquals(0L, u32(rst, i.l4 + 8)) // 0xFFFFFFFF + 1
        }
    }

    @Test
    fun tcpResetCountsDataInItsAck() {
        val req = clientTcp(true, 100, 0, IpPacket.PSH, payload)
        val rst = IpPacket.tcpReset(req, req.size, parsed(req))!!
        assertEquals(100L + payload.size, u32(rst, 40 + 8))
    }

    @Test
    fun neverResetsAReset() {
        for (v6 in listOf(false, true)) {
            val req = clientTcp(v6, 1, 1, IpPacket.RST)
            assertNull(IpPacket.tcpReset(req, req.size, parsed(req)))
        }
    }

    // --- ICMP -----------------------------------------------------------------------------

    @Test
    fun icmpV4PortUnreachableQuotesTheOffendingDatagram() {
        val req = PacketCheck.udpPacket(false, V4_CLIENT, V4_8888, 41000, 443, ByteArray(1200) { 9 })
        val p = parsed(req)
        val icmp = IpPacket.icmpPortUnreachable(req, req.size, p)!!
        val i = PacketCheck.verify(icmp)
        assertEquals(IpPacket.PROTO_ICMP, i.proto)
        assertArrayEquals(V4_8888, i.src); assertArrayEquals(V4_CLIENT, i.dst)
        assertEquals(3, icmp[20].toInt()); assertEquals(3, icmp[21].toInt())
        // cabecera IP original + 8 bytes de UDP, y nada más
        assertArrayEquals(req.copyOfRange(0, 28), icmp.copyOfRange(28, icmp.size))
        assertEquals(20 + 8 + 28, icmp.size)
    }

    @Test
    fun icmpV6PortUnreachableHasAPseudoHeaderChecksum() {
        val req = PacketCheck.udpPacket(true, V6_CLIENT, V6_GOOGLE, 41000, 443, ByteArray(1200) { 9 })
        val icmp = IpPacket.icmpPortUnreachable(req, req.size, parsed(req))!!
        val i = PacketCheck.verify(icmp)
        assertEquals(IpPacket.PROTO_ICMP6, i.proto)
        assertArrayEquals(V6_GOOGLE, i.src); assertArrayEquals(V6_CLIENT, i.dst)
        assertEquals(1, icmp[40].toInt()); assertEquals(4, icmp[41].toInt())
        assertArrayEquals(req.copyOfRange(0, 128), icmp.copyOfRange(48, icmp.size))
        assertTrue(icmp.size <= 1280) // nunca supera el MTU mínimo de IPv6
    }

    @Test
    fun icmpV6QuotesShortPacketsWhole() {
        val req = PacketCheck.udpPacket(true, V6_CLIENT, V6_GOOGLE, 41000, 853, ByteArray(3))
        val icmp = IpPacket.icmpPortUnreachable(req, req.size, parsed(req))!!
        PacketCheck.verify(icmp)
        assertArrayEquals(req, icmp.copyOfRange(48, icmp.size))
    }

    @Test
    fun noPortUnreachableForNonUdp() {
        val req = clientTcp(false, 1, 1, IpPacket.ACK)
        assertNull(IpPacket.icmpPortUnreachable(req, req.size, parsed(req)))
    }

    private fun echo(type: Int, data: ByteArray): ByteArray {
        val e = ByteArray(8 + data.size)
        e[0] = type.toByte(); e[4] = 0x12; e[5] = 0x34; e[6] = 0; e[7] = 7
        System.arraycopy(data, 0, e, 8, data.size)
        return e
    }

    @Test
    fun echoRequestsGetValidEchoReplies() {
        val data = ByteArray(33) { it.toByte() }
        val r4 = PacketCheck.v4(1, V4_CLIENT, V4_8888, echo(8, data))
        val rep4 = IpPacket.icmpEchoReply(r4, r4.size, parsed(r4))!!
        val i4 = PacketCheck.verify(rep4)
        assertArrayEquals(V4_8888, i4.src); assertEquals(0, rep4[20].toInt())
        assertArrayEquals(r4.copyOfRange(24, r4.size), rep4.copyOfRange(24, rep4.size)) // id, secuencia y datos

        val seg6 = echo(128, data)
        val r6 = PacketCheck.v6(58, V6_CLIENT, V6_GOOGLE, seg6)
        // el ping de verdad lleva checksum; el nuestro no lo comprueba, pero la respuesta sí debe llevarlo
        val rep6 = IpPacket.icmpEchoReply(r6, r6.size, parsed(r6))!!
        val i6 = PacketCheck.verify(rep6)
        assertArrayEquals(V6_GOOGLE, i6.src); assertEquals(129, rep6[40].toInt() and 0xFF)
        assertArrayEquals(r6.copyOfRange(44, r6.size), rep6.copyOfRange(44, rep6.size))
    }

    @Test
    fun onlyEchoRequestsAreAnswered() {
        val r4 = PacketCheck.v4(1, V4_CLIENT, V4_8888, echo(0, ByteArray(4))) // ya es una respuesta
        assertNull(IpPacket.icmpEchoReply(r4, r4.size, parsed(r4)))
        val r6 = PacketCheck.v6(58, V6_CLIENT, V6_GOOGLE, echo(135, ByteArray(4))) // vecino, no eco
        assertNull(IpPacket.icmpEchoReply(r6, r6.size, parsed(r6)))
        assertNotNull(IpPacket.icmpEchoReply(PacketCheck.v4(1, V4_CLIENT, V4_8888, echo(8, ByteArray(0))).let { it }, 28, IpPacket.Parsed(false, 20, 8, 1)))
    }
}
