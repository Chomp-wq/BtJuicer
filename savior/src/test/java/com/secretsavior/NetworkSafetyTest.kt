package com.secretsavior

import com.secretsavior.vpn.DnsPacket
import com.secretsavior.vpn.Subnets
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class NetworkSafetyTest {

    private fun ip(a: Int, b: Int, c: Int, d: Int) = (a shl 24) or (b shl 16) or (c shl 8) or d

    private fun query(name: String, edns: Int? = null, flags: Int = 0x0100): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf(0x12, 0x34, (flags shr 8).toByte(), flags.toByte(), 0, 1, 0, 0, 0, 0, 0, if (edns != null) 1 else 0))
        for (l in name.split('.')) { b.write(l.length); b.write(l.toByteArray()) }
        b.write(0); b.write(0); b.write(1); b.write(0); b.write(1)
        if (edns != null) b.write(byteArrayOf(0, 0, 41, (edns shr 8).toByte(), edns.toByte(), 0, 0, 0, 0, 0, 0))
        return b.toByteArray()
    }

    // --- Subredes -------------------------------------------------------------------------

    @Test
    fun theUsualSubnetIsKeptWhenNothingClashes() {
        val c = Subnets.pick(listOf(ip(192, 168, 1, 0) to 24, ip(10, 0, 0, 5) to 30))
        assertEquals("10.255.255.1", c.dns)
        assertEquals("10.255.255.2", c.address)
        assertEquals("10.255.255.0", c.network)
        assertArrayEquals(byteArrayOf(10, -1, -1, 1), c.dnsBytes)
    }

    @Test
    fun aRealNetworkOnTheSameSubnetMakesItPickAnother() {
        // Un router en 10.255.255.x: con el túnel encima el teléfono dejaba de verlo.
        val c = Subnets.pick(listOf(ip(10, 255, 255, 37) to 24))
        assertEquals("172.31.255.1", c.dns)
        assertArrayEquals(byteArrayOf(172.toByte(), 31, -1, 1), c.dnsBytes)
    }

    @Test
    fun aWideNetworkContainingItCounts() {
        assertEquals("172.31.255.1", Subnets.pick(listOf(ip(10, 0, 0, 0) to 8)).dns)
    }

    @Test
    fun aDefaultRouteIsNotAClash() {
        assertEquals("10.255.255.1", Subnets.pick(listOf(0 to 0)).dns)
    }

    @Test
    fun itWalksThroughTheCandidates() {
        val used = listOf(ip(10, 255, 255, 0) to 24, ip(172, 31, 255, 0) to 24, ip(198, 18, 255, 9) to 30)
        assertEquals("192.0.2.1", Subnets.pick(used).dns)
    }

    @Test
    fun withEveryCandidateTakenItFallsBackToTheFirst() {
        val used = Subnets.CANDIDATES.map { it.base to 24 }
        assertEquals("10.255.255.1", Subnets.pick(used).dns)
    }

    @Test
    fun overlapRespectsPrefixLength() {
        assertTrue(Subnets.overlaps(ip(10, 255, 255, 0), 24, ip(10, 255, 255, 200), 32))
        assertFalse(Subnets.overlaps(ip(10, 255, 255, 0), 24, ip(10, 255, 254, 0), 24))
        assertTrue(Subnets.overlaps(ip(10, 255, 255, 0), 24, ip(10, 0, 0, 0), 8))
    }

    // --- Paquetes -------------------------------------------------------------------------

    @Test
    fun questionKeyIgnoresCaseAndOtherFields() {
        assertEquals("example.com/1/1", DnsPacket.questionKey(query("Example.COM")))
        val response = query("example.com").also { it[2] = (it[2].toInt() or 0x80).toByte() }
        assertEquals(DnsPacket.questionKey(query("example.com")), DnsPacket.questionKey(response))
        assertTrue(DnsPacket.questionKey(query("a.com")) != DnsPacket.questionKey(query("b.com")))
    }

    @Test
    fun questionKeyRejectsGarbage() {
        assertNull(DnsPacket.questionKey(ByteArray(5)))
        assertNull(DnsPacket.questionKey(ByteArray(20))) // sin pregunta
    }

    @Test
    fun responseAndTruncatedFlagsAreRead() {
        val r = query("example.com").also { it[2] = (it[2].toInt() or 0x82).toByte() }
        assertTrue(DnsPacket.isResponse(r))
        assertTrue(DnsPacket.isTruncated(r))
        assertFalse(DnsPacket.isResponse(query("example.com")))
        assertFalse(DnsPacket.isTruncated(query("example.com")))
    }

    @Test
    fun ednsSizeComesFromTheOptRecord() {
        assertEquals(512, DnsPacket.ednsSize(query("example.com")))
        assertEquals(1232, DnsPacket.ednsSize(query("example.com", edns = 1232)))
        assertEquals(4096, DnsPacket.ednsSize(query("example.com", edns = 4096)))
        assertEquals(512, DnsPacket.ednsSize(query("example.com", edns = 100))) // nunca por debajo
    }
}
