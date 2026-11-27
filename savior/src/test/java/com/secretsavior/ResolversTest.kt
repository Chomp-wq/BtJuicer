package com.secretsavior

import com.secretsavior.vpn.DnsFilter
import com.secretsavior.vpn.DnsPipeline
import com.secretsavior.vpn.DnsPacket
import com.secretsavior.vpn.Resolvers
import com.secretsavior.vpn.SaviorVpnService
import com.secretsavior.vpn.Subnets
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class ResolversTest {

    private fun a(s: String) = InetAddress.getByName(s)

    /** Los resolutores aguas arriba, tal como los declara el servicio. */
    private val upstreams = (SaviorVpnService.PRIMARY + SaviorVpnService.FALLBACK).mapNotNull { it.address }

    private val table = Resolvers.build(upstreams)

    @Test
    fun everyEntryParses() {
        // build() las parsea todas y lanza si alguna no es una dirección o un prefijo válido
        assertTrue(Resolvers.entries().size > 140)
        assertTrue(table.routes.size > 140)
        for (e in Resolvers.entries()) Resolvers.parse(e.substringBefore('/'))
    }

    @Test
    fun theBigNamesAreCaptured() {
        for (ip in listOf(
            "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "94.140.14.14", "45.90.28.77", "45.90.30.200", "76.76.2.2", "194.242.2.2",
            "185.222.222.222", "193.110.81.0", "149.112.121.10", "77.88.8.8", "223.5.5.5", "119.29.29.29",
            "101.226.4.6", "185.228.168.9", "4.2.2.1", "64.6.64.6",
            "2001:4860:4860::8888", "2606:4700:4700::1111", "2620:fe::fe", "2a10:50c0::ad1:ff",
            "2a07:a8c0::ab:cdef", "2a07:a8c1:1234::1", "2a0d:2a00:1::2",
        )) assertTrue("$ip debería capturarse", table.contains(a(ip)))
    }

    @Test
    fun ordinaryAddressesAreNotCaptured() {
        for (ip in listOf(
            "8.8.8.9", "1.1.1.4", "45.90.29.1", "192.168.1.1", "10.0.0.1", "142.250.80.46", "151.101.1.1",
            "2001:4860:4860::8889", "2a00:1450:4001:81b::200e", "2a07:a8c2::1",
        )) assertFalse("$ip no debería capturarse", table.contains(a(ip)))
    }

    @Test
    fun ourOwnUpstreamsAreNeverCaptured() {
        assertTrue(upstreams.size >= 8)
        for (u in upstreams) assertFalse("${u.hostAddress} es nuestro resolutor", table.contains(u))
        for (r in table.routes) for (u in upstreams) {
            assertFalse("la ruta ${r.inet.hostAddress}/${r.prefix} cubre ${u.hostAddress}", covers(r, u))
        }
    }

    @Test
    fun anExclusionAlsoDropsAPrefixThatWouldCoverIt() {
        val t = Resolvers.build(listOf(a("45.90.28.5")))
        assertFalse(t.contains(a("45.90.28.5")))
        assertFalse(t.contains(a("45.90.28.77"))) // el /24 entero se descarta
        assertTrue(t.contains(a("45.90.30.77")))
    }

    @Test
    fun noRouteOverlapsTheTunnelSubnets() {
        for (r in table.routes.filter { !it.v6 }) {
            val ip = Subnets.toInt(r.address)
            for (c in Subnets.CANDIDATES) {
                assertFalse(
                    "${r.inet.hostAddress}/${r.prefix} pisa el túnel ${c.network}",
                    Subnets.overlaps(ip, r.prefix, c.base, 24),
                )
            }
        }
        // ni nada que se parezca a la ULA del túnel ni a un rango privado
        for (r in table.routes.filter { it.v6 }) assertTrue((r.address[0].toInt() and 0xFE) != 0xFC)
        for (r in table.routes.filter { !it.v6 }) {
            val b0 = r.address[0].toInt() and 0xFF
            assertTrue(b0 != 10 && b0 != 127 && b0 != 0 && b0 < 224)
        }
    }

    @Test
    fun routesAreWellFormedAndMatchTheTable() {
        for (r in table.routes) {
            assertEquals(if (r.v6) 16 else 4, r.address.size)
            assertTrue(r.prefix in 1..(if (r.v6) 128 else 32))
            // la dirección de una ruta no tiene bits fuera del prefijo
            for (bit in r.prefix until r.address.size * 8) {
                assertEquals("bits de host en ${r.inet.hostAddress}/${r.prefix}", 0, (r.address[bit / 8].toInt() shr (7 - bit % 8)) and 1)
            }
            assertTrue("${r.inet.hostAddress} debe estar en la tabla", table.contains(r.inet))
        }
        assertTrue(table.routes.any { !it.v6 && it.prefix == 24 }) // los prefijos de anycast
        assertTrue(table.routes.any { it.v6 && it.prefix == 32 })
        assertTrue(table.routes.count { it.v6 } > 45 && table.routes.count { !it.v6 } > 85)
        assertTrue(table.routes.size < 400) // cada una es una ruta en la VPN
    }

    @Test
    fun noDuplicateRoutes() {
        val keys = table.routes.map { it.address.toList() to it.prefix }
        assertEquals(keys.size, keys.toSet().size)
    }

    private fun covers(r: Resolvers.Route, u: InetAddress): Boolean {
        val b = u.address
        if (b.size != r.address.size) return false
        for (bit in 0 until r.prefix) {
            val m = 1 shl (7 - bit % 8)
            if ((b[bit / 8].toInt() and m) != (r.address[bit / 8].toInt() and m)) return false
        }
        return true
    }

    // --- Memo de DnsFilter ----------------------------------------------------------------

    @After
    fun resetExtra() {
        DnsFilter.extra = emptySet()
    }

    @Test
    fun memoReturnsTheSameAnswerAsTheFilter() {
        for (n in listOf("xvideos.com", "www.xvideos.com.", "WWW.XVIDEOS.COM", "example.org", "", "pornharms.com", "a.sex.example")) {
            val first = DnsFilter.isBlocked(n)
            assertEquals(first, DnsFilter.isBlocked(n)) // ya memorizado
        }
        assertTrue(DnsFilter.isBlocked("xvideos.com"))
        assertFalse(DnsFilter.isBlocked("example.org"))
        assertFalse(DnsFilter.isBlocked("pornharms.com")) // la lista blanca sigue ganando
    }

    @Test
    fun changingExtraInvalidatesTheMemo() {
        assertFalse(DnsFilter.isBlocked("mi-sitio.example"))
        assertFalse(DnsFilter.isBlocked("mi-sitio.example")) // memorizado como "no"
        DnsFilter.extra = setOf("mi-sitio.example")
        assertTrue(DnsFilter.isBlocked("mi-sitio.example"))
        assertTrue(DnsFilter.isBlocked("sub.mi-sitio.example"))
        DnsFilter.extra = emptySet() // sólo se añade en la app, pero la caché no debe inventar nada
        assertFalse(DnsFilter.isBlocked("mi-sitio.example"))
    }

    @Test
    fun memoStaysBoundedAndStillCorrectAfterOverflow() {
        for (i in 0 until 10_000) DnsFilter.isBlocked("host$i.example.net")
        assertTrue(DnsFilter.isBlocked("xvideos.com"))
        assertFalse(DnsFilter.isBlocked("host5.example.net"))
    }

    @Test
    fun memoIsSafeUnderConcurrentUse() {
        val bad = java.util.concurrent.atomic.AtomicInteger()
        val threads = (0 until 4).map { t ->
            Thread {
                for (i in 0 until 20_000) {
                    if (i % 500 == 0) DnsFilter.extra = if ((i / 500) % 2 == 0) emptySet() else setOf("x$t.example")
                    if (!DnsFilter.isBlocked("www.xvideos.com")) bad.incrementAndGet()
                    if (DnsFilter.isBlocked("example.org")) bad.incrementAndGet()
                }
            }.also { it.start() }
        }
        threads.forEach { it.join() }
        assertEquals(0, bad.get())
    }

    // --- Pipeline -------------------------------------------------------------------------

    private fun query(name: String, type: Int = 1): ByteArray = DnsPacket.query(name, type).also { it[0] = 0x12; it[1] = 0x34 }

    @Test
    fun pipelineAnswersBlockedAndCanaryLocally() {
        var counted = 0
        val p = DnsPipeline({ null }, { counted++ })
        var r: ByteArray? = null
        p.resolve(query("xvideos.com")) { r = it }
        val q = DnsPacket.parseQuestion(query("xvideos.com"))!!
        assertArrayEquals(DnsPacket.blocked(query("xvideos.com"), q), r)
        assertEquals(1, counted)
        p.resolve(query("xvideos.com", DnsPacket.TYPE_AAAA)) { r = it }
        assertEquals(1, counted) // sólo cuenta las A

        p.resolve(query("use-application-dns.net")) { r = it }
        assertEquals(3, r!![3].toInt() and 0x0F) // NXDOMAIN
    }

    @Test
    fun pipelineWithoutForwarderFailsFastInsteadOfHanging() {
        val p = DnsPipeline({ null })
        var r: ByteArray? = null
        var called = 0
        p.resolve(query("example.org")) { r = it; called++ }
        assertEquals(1, called)
        assertEquals(2, r!![3].toInt() and 0x0F) // SERVFAIL
        p.resolve(query("www.google.com")) { r = it } // búsqueda segura sin reenviador: falla, no pasa sin filtrar
        assertEquals(2, r!![3].toInt() and 0x0F)
        p.resolve(query("www.google.com", 65)) { r = it } // HTTPS/SVCB: vacío
        assertEquals(0, r!![3].toInt() and 0x0F)
        assertEquals(0, ((r!![6].toInt() and 0xFF) shl 8) or (r!![7].toInt() and 0xFF))
        var none: ByteArray? = byteArrayOf(1)
        p.resolve(ByteArray(5)) { none = it } // ilegible y sin reenviador: nada que contestar
        assertNull(none)
        assertNotNull(r)
    }
}
