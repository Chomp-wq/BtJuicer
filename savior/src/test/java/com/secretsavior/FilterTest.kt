package com.secretsavior

import com.secretsavior.guard.ContentRules
import com.secretsavior.vpn.DnsFilter
import com.secretsavior.vpn.DnsPacket
import com.secretsavior.vpn.IpPacket
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class FilterTest {

    @After
    fun reset() {
        DnsFilter.extra = emptySet()
    }

    @Test
    fun blocksAdultDomains() {
        for (d in listOf(
            "pornhub.com", "www.xvideos.com", "cdn.XNXX.com.", "foo.xxx", "free-sex-videos.net",
            "a.hentai-world.org", "chaturbate.com", "sub.phncdn.com",
        )) assertTrue(d, DnsFilter.isBlocked(d))
    }

    @Test
    fun blocksEncryptedDnsProviders() {
        for (d in listOf("dns.google", "cloudflare-dns.com", "mozilla.cloudflare-dns.com"))
            assertTrue(d, DnsFilter.isBlocked(d))
    }

    @Test
    fun leavesOrdinaryDomainsAlone() {
        for (d in listOf(
            "google.com", "essex.ac.uk", "sussex.edu", "popcorn.com", "xxxlutz.de", "wikipedia.org",
            "github.com", "middlesex.gov", "scunthorpe.gov.uk", "sexta.es", "facebook.com",
        )) assertFalse(d, DnsFilter.isBlocked(d))
    }

    @Test
    fun recoveryResourcesAreNotBlocked() {
        for (d in listOf("pornharms.com", "www.covenanteyes.com", "nofap.com", "yourbrainonporn.com"))
            assertFalse(d, DnsFilter.isBlocked(d))
    }

    @Test
    fun userDomainsAreAddedAndNormalized() {
        DnsFilter.extra = setOf("miweb.example.com")
        assertTrue(DnsFilter.isBlocked("a.miweb.example.com"))
        assertEquals("foo.com", DnsFilter.normalize("https://Foo.com/x?y"))
        assertNull(DnsFilter.normalize("no es dominio"))
        assertNull(DnsFilter.normalize("a.b"))
    }

    @Test
    fun blockedAnswerForA() {
        val q = query("pornhub.com", DnsPacket.TYPE_A)
        val parsed = DnsPacket.parseQuestion(q)!!
        assertEquals("pornhub.com", parsed.name)
        assertEquals(q.size, parsed.end)
        val r = DnsPacket.blocked(q, parsed)
        assertEquals(q.size + 16, r.size)
        assertEquals(1, r[7].toInt())
        assertTrue(r.copyOfRange(r.size - 4, r.size).all { it.toInt() == 0 })
        assertNull("una respuesta no es una consulta", DnsPacket.parseQuestion(r))
    }

    @Test
    fun blockedAnswerForAaaaAndOthers() {
        val q6 = query("pornhub.com", DnsPacket.TYPE_AAAA)
        assertEquals(q6.size + 28, DnsPacket.blocked(q6, DnsPacket.parseQuestion(q6)!!).size)
        val mx = query("pornhub.com", 15)
        assertEquals(mx.size, DnsPacket.blocked(mx, DnsPacket.parseQuestion(mx)!!).size)
    }

    @Test
    fun servfailCarriesTheRcode() {
        val q = query("example.com", DnsPacket.TYPE_A)
        assertEquals(2, DnsPacket.servfail(q, DnsPacket.parseQuestion(q)!!)[3].toInt() and 0xF)
    }

    @Test
    fun garbageIsNotAQuery() {
        assertNull(DnsPacket.parseQuestion(ByteArray(5)))
    }

    @Test
    fun udpReplySwapsEndpointsAndChecksums() {
        val dns = byteArrayOf(10, -1, -1, 1)
        val phone = byteArrayOf(10, -1, -1, 2)
        val req = ByteArray(28 + 4)
        req[0] = 0x45; req[9] = 17
        phone.copyInto(req, 12); dns.copyInto(req, 16)
        req[20] = 0x15; req[21] = 0xB3.toByte(); req[22] = 0; req[23] = 53
        val payload = ByteArray(10) { it.toByte() }
        val rep = IpPacket.udpReply(req, 20, payload)
        assertEquals(0, IpPacket.checksum(rep, 0, 20))
        assertArrayEquals(dns, rep.copyOfRange(12, 16))
        assertArrayEquals(phone, rep.copyOfRange(16, 20))
        assertEquals(0, rep[20].toInt()); assertEquals(53, rep[21].toInt())
        assertEquals(0x15, rep[22].toInt())
        assertEquals(8 + payload.size, ((rep[24].toInt() and 0xFF) shl 8) or (rep[25].toInt() and 0xFF))
    }

    @Test
    fun tcpSynGetsAValidResetAndRstGetsNone() {
        val syn = ByteArray(40)
        syn[0] = 0x45; syn[9] = 6
        byteArrayOf(10, -1, -1, 2).copyInto(syn, 12); byteArrayOf(10, -1, -1, 1).copyInto(syn, 16)
        syn[20] = 0x30; syn[21] = 0x39; syn[22] = 0x03; syn[23] = 0x55 // 12345 -> 853
        syn[27] = 100 // seq
        syn[32] = 0x50; syn[33] = 0x02 // SYN
        val rst = IpPacket.tcpReset(syn, 40, 20)!!
        assertEquals(0, IpPacket.checksum(rst, 0, 20))
        assertEquals(0x14, rst[33].toInt()) // RST + ACK
        assertEquals(101, rst[31].toInt())  // ack = seq + 1
        val pseudo = ByteArray(32)
        rst.copyInto(pseudo, 0, 12, 20); pseudo[9] = 6; pseudo[11] = 20; rst.copyInto(pseudo, 12, 20, 40)
        assertEquals(0, IpPacket.checksum(pseudo, 0, 32))
        syn[33] = 0x04
        assertNull(IpPacket.tcpReset(syn, 40, 20))
    }

    @Test
    fun explicitTextEverywhere() {
        for (t in listOf("pornhub", "ver porno gratis", "Pornografía", "HENTAI"))
            assertTrue(t, ContentRules.isExplicit(t, inBrowser = false))
    }

    @Test
    fun broaderRulesOnlyInBrowsers() {
        for (t in listOf("xxx", "sexo video gratis", "fotos de tetas", "desnudas", "sex cams")) {
            assertTrue(t, ContentRules.isExplicit(t, inBrowser = true))
            assertFalse(t, ContentRules.isExplicit(t, inBrowser = false))
        }
    }

    @Test
    fun ordinaryTextPasses() {
        for (t in listOf("hola, te quiero xxx", "popcorn", "Essex", "educación sexual", "hora de comer"))
            assertFalse(t, ContentRules.isExplicit(t, inBrowser = false))
        for (t in listOf("popcorn", "Essex", "educación sexual", "https://github.com/foo"))
            assertFalse(t, ContentRules.isExplicit(t, inBrowser = true))
    }

    private fun query(name: String, type: Int): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf(0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0))
        for (l in name.split('.')) { b.write(l.length); b.write(l.toByteArray()) }
        b.write(0); b.write(0); b.write(type); b.write(0); b.write(1)
        return b.toByteArray()
    }
}
