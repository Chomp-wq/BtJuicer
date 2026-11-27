package com.secretsavior

import com.secretsavior.guard.ContentRules
import com.secretsavior.vpn.DnsFilter
import com.secretsavior.vpn.DnsPacket
import com.secretsavior.vpn.SafeSearch
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class SafeSearchTest {

    // --- A qué nombre se desvía cada buscador ---------------------------------------------

    @Test
    fun searchEnginesAreSentToTheirSafeName() {
        for (n in listOf("google.com", "www.google.com", "WWW.Google.Com.", "www.google.es", "www.google.com.mx", "google.co.uk"))
            assertEquals(n, "forcesafesearch.google.com", SafeSearch.target(n))
        for (n in listOf("duckduckgo.com", "www.duckduckgo.com", "start.duckduckgo.com"))
            assertEquals(n, "safe.duckduckgo.com", SafeSearch.target(n))
        assertEquals("strict.bing.com", SafeSearch.target("www.bing.com"))
        assertEquals("familysearch.yandex.ru", SafeSearch.target("yandex.com"))
        assertEquals("familysearch.yandex.ru", SafeSearch.target("ya.ru"))
    }

    @Test
    fun everythingElseIsLeftAlone() {
        for (n in listOf(
            "mail.google.com", "accounts.google.com", "play.google.com", "google.dev", "www.googleapis.com",
            "fonts.gstatic.com", "notgoogle.com", "google.com.evil.net", "youtube.com", "www.youtube.com",
            "links.duckduckgo.com", "external-content.duckduckgo.com", "th.bing.com", "mybing.com",
            "forcesafesearch.google.com", "safe.duckduckgo.com", "strict.bing.com", "playa.ru", "example.com",
        )) assertNull(n, SafeSearch.target(n))
    }

    // --- Paquetes -------------------------------------------------------------------------

    private fun name(b: ByteArrayOutputStream, n: String) {
        for (l in n.split('.')) { b.write(l.length); b.write(l.toByteArray()) }
        b.write(0)
    }

    private fun clientQuery(n: String, type: Int): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf(0x55, 0x66, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1)) // con un OPT de EDNS detrás
        name(b, n); b.write(byteArrayOf(0, type.toByte(), 0, 1))
        b.write(byteArrayOf(0, 0, 41, 4, -48, 0, 0, 0, 0, 0, 0))
        return b.toByteArray()
    }

    /** Lo que contestaría el resolutor a la consulta por el nombre seguro: un CNAME y dos direcciones. */
    private fun upstream(safe: String, type: Int, rcode: Int = 0, vararg addresses: ByteArray): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf(0, 0, 0x81.toByte(), (0x80 or rcode).toByte(), 0, 1, 0, (addresses.size + 1).toByte(), 0, 0, 0, 0))
        name(b, safe); b.write(byteArrayOf(0, type.toByte(), 0, 1))
        // CNAME hacia otro nombre, con el nombre escrito entero
        b.write(byteArrayOf(0xC0.toByte(), 0x0C, 0, 5, 0, 1, 0, 0, 0, 9, 0, 6, 3, 'f'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 0xC0.toByte(), 0x0C))
        for (a in addresses) {
            b.write(byteArrayOf(0xC0.toByte(), 0x0C, 0, type.toByte(), 0, 1, 0, 0, 1, 0x2C, 0, a.size.toByte()))
            b.write(a)
        }
        return b.toByteArray()
    }

    @Test
    fun aBuiltQueryIsAValidQuery() {
        val q = DnsPacket.query("forcesafesearch.google.com", DnsPacket.TYPE_A)
        val parsed = DnsPacket.parseQuestion(q)!!
        assertEquals("forcesafesearch.google.com", parsed.name)
        assertEquals(DnsPacket.TYPE_A, parsed.type)
        assertEquals(q.size, parsed.end)
        assertEquals("forcesafesearch.google.com/1/1", DnsPacket.questionKey(q))
    }

    @Test
    fun theAnswerCarriesTheSafeAddressesUnderTheOriginalName() {
        val query = clientQuery("www.google.com", DnsPacket.TYPE_A)
        val q = DnsPacket.parseQuestion(query)!!
        val safeIp = byteArrayOf(216.toByte(), 239.toByte(), 38, 120)
        val r = DnsPacket.retarget(query, q, upstream("forcesafesearch.google.com", 1, 0, safeIp, byteArrayOf(1, 2, 3, 4)))!!
        assertEquals("el id del cliente", 0x55, r[0].toInt()); assertEquals(0x66, r[1].toInt())
        assertTrue(DnsPacket.isResponse(r))
        assertEquals("www.google.com/1/1", DnsPacket.questionKey(r))
        assertEquals("dos direcciones, sin el CNAME", 2, r[7].toInt())
        assertEquals("sin sección adicional", 0, r[11].toInt())
        assertEquals(q.end + 2 * 16, r.size)
        assertArrayEquals(safeIp, r.copyOfRange(q.end + 12, q.end + 16))
        assertArrayEquals("TTL del resolutor", byteArrayOf(0, 0, 1, 0x2C), r.copyOfRange(q.end + 6, q.end + 10))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), r.copyOfRange(r.size - 4, r.size))
    }

    @Test
    fun ipv6AnswersAreCarriedToo() {
        val query = clientQuery("duckduckgo.com", DnsPacket.TYPE_AAAA)
        val q = DnsPacket.parseQuestion(query)!!
        val v6 = ByteArray(16) { (it + 1).toByte() }
        val r = DnsPacket.retarget(query, q, upstream("safe.duckduckgo.com", 28, 0, v6))!!
        assertEquals(1, r[7].toInt())
        assertArrayEquals(v6, r.copyOfRange(r.size - 16, r.size))
    }

    @Test
    fun noAddressesMeansAnEmptyAnswerAndAnErrorMeansNull() {
        val query = clientQuery("www.bing.com", DnsPacket.TYPE_AAAA)
        val q = DnsPacket.parseQuestion(query)!!
        val empty = DnsPacket.retarget(query, q, upstream("strict.bing.com", 28))!!
        assertEquals(0, empty[7].toInt())
        assertEquals(q.end, empty.size)
        assertNull("NXDOMAIN del nombre seguro", DnsPacket.retarget(query, q, upstream("strict.bing.com", 28, rcode = 3)))
        assertNull("basura", DnsPacket.retarget(query, q, ByteArray(7)))
        val cut = upstream("strict.bing.com", 28, 0, ByteArray(16))
        assertNull("respuesta a medias", DnsPacket.retarget(query, q, cut.copyOf(cut.size - 5)))
    }

    @Test
    fun nxdomainIsAnEmptyNameError() {
        val query = clientQuery("use-application-dns.net", DnsPacket.TYPE_A)
        val q = DnsPacket.parseQuestion(query)!!
        val r = DnsPacket.nxdomain(query, q)
        assertEquals(3, r[3].toInt() and 0x0F)
        assertEquals(0, r[7].toInt())
        assertEquals(q.end, r.size)
        assertTrue(DnsPacket.isResponse(r))
    }

    // --- Filtro ---------------------------------------------------------------------------

    @Test
    fun firefoxCanaryIsRecognised() {
        assertTrue(DnsFilter.isCanary("use-application-dns.net"))
        assertTrue(DnsFilter.isCanary("Use-Application-DNS.net."))
        assertFalse(DnsFilter.isCanary("example.net"))
    }

    @Test
    fun moreEncryptedDnsProvidersAndSitesAreBlocked() {
        for (d in listOf(
            "dns.adguard-dns.com", "unfiltered.adguard-dns.com", "adblock.dns.mullvad.net", "zero.dns0.eu",
            "private.canadianshield.cira.ca", "chrome.cloudflare-dns.com", "rule34video.com", "www.youjizz.com",
            "poringa.net", "missav.ws", "relatos-eroticos.es", "nsfwalbum.com",
        )) assertTrue(d, DnsFilter.isBlocked(d))
        for (d in listOf("heroticket.com", "cira.ca", "mullvad.net", "quad9.net", "nic.cz", "he.net", "controld.com", "milford.com"))
            assertFalse(d, DnsFilter.isBlocked(d))
    }

    // --- Barra de direcciones ---------------------------------------------------------------

    @Test
    fun hostIsExtractedWithoutBeingFooled() {
        assertEquals("example.com", ContentRules.hostOf("https://example.com/a/b?c#d"))
        assertEquals("example.com", ContentRules.hostOf("Example.com:8443/x"))
        assertEquals("evil.com", ContentRules.hostOf("https://nofap.com:x@evil.com/"))
        assertEquals("evil.com", ContentRules.hostOf("https://nofap.com@evil.com?q=1"))
    }

    @Test
    fun recoveryArticlesAreNotClosedButTheRestStillIs() {
        assertFalse(ContentRules.urlLooksBlocked("https://fightthenewdrug.org/how-porn-changes-the-brain/"))
        assertFalse(ContentRules.urlLooksBlocked("www.nofap.com/porn-addiction"))
        assertFalse(ContentRules.urlLooksBlocked("pornharms.com"))
        assertTrue(ContentRules.urlLooksBlocked("https://www.google.com/search?q=porn"))
        assertTrue(ContentRules.urlLooksBlocked("pornhub.com"))
        assertTrue(ContentRules.urlLooksBlocked("https://x.com/home"))
        assertTrue("no vale disfrazarse de sitio de ayuda", ContentRules.urlLooksBlocked("https://nofap.com@pornhub.com/"))
        assertTrue("ni citarlo en una búsqueda", ContentRules.urlLooksBlocked("porn nofap.com"))
        assertFalse(ContentRules.urlLooksBlocked("https://github.com/foo"))
        assertFalse(ContentRules.urlLooksBlocked(""))
    }
}
