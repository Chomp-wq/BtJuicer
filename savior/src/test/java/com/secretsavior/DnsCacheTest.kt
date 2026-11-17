package com.secretsavior

import com.secretsavior.vpn.DnsCache
import com.secretsavior.vpn.DnsPacket
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class DnsCacheTest {

    private var now = 1_000_000L
    private fun cache(maxEntries: Int = 2048, maxStaleMs: Long = 3 * 3600_000L) =
        DnsCache(maxEntries = maxEntries, maxStaleMs = maxStaleMs, staleTtlSec = 10, clock = { now })

    // --- Paquetes -------------------------------------------------------------------------

    private class Rec(val type: Int, val ttl: Long, val rdata: ByteArray)

    private fun name(b: ByteArrayOutputStream, n: String) {
        for (l in n.split('.').filter { it.isNotEmpty() }) { b.write(l.length); b.write(l.toByteArray()) }
        b.write(0)
    }

    private fun u32(b: ByteArrayOutputStream, v: Long) {
        b.write((v shr 24).toInt()); b.write((v shr 16).toInt()); b.write((v shr 8).toInt()); b.write(v.toInt())
    }

    private fun query(n: String, id: Int = 0x1111, type: Int = 1, edns: Int? = null, opcode: Int = 0): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf((id shr 8).toByte(), id.toByte(), (1 or (opcode shl 3)).toByte(), 0, 0, 1, 0, 0, 0, 0, 0, if (edns != null) 1 else 0))
        name(b, n); b.write(0); b.write(type); b.write(0); b.write(1)
        if (edns != null) b.write(byteArrayOf(0, 0, 41, (edns shr 8).toByte(), edns.toByte(), 0, 0, 0, 0, 0, 0))
        return b.toByteArray()
    }

    private fun a(ttl: Long, ip: Int = 1) = Rec(1, ttl, byteArrayOf(10, 0, 0, ip.toByte()))

    private fun soa(ttl: Long, minimum: Long): Rec {
        val r = ByteArrayOutputStream()
        name(r, "ns.example.com"); name(r, "root.example.com")
        repeat(4) { u32(r, 1) }
        u32(r, minimum)
        return Rec(6, ttl, r.toByteArray())
    }

    /** Respuesta a [n] con los registros dados (el dueño va como puntero 0xC00C) y un OPT opcional con "TTL" 0x00008000. */
    private fun response(
        n: String, answers: List<Rec> = listOf(a(60)), authority: List<Rec> = emptyList(),
        rcode: Int = 0, tc: Boolean = false, opt: Boolean = false, qname: String = n, type: Int = 1, id: Int = 0x7777,
    ): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf((id shr 8).toByte(), id.toByte(), (0x81 or (if (tc) 0x02 else 0)).toByte(), (0x80 or rcode).toByte()))
        b.write(byteArrayOf(0, 1, 0, answers.size.toByte(), 0, authority.size.toByte(), 0, if (opt) 1 else 0))
        name(b, qname); b.write(0); b.write(type); b.write(0); b.write(1)
        for (r in answers + authority) {
            b.write(0xC0); b.write(0x0C)
            b.write(0); b.write(r.type); b.write(0); b.write(1)
            u32(b, r.ttl)
            b.write(0); b.write(r.rdata.size); b.write(r.rdata)
        }
        if (opt) b.write(byteArrayOf(0, 0, 41, 16, 0, 0, 0, 0x80.toByte(), 0, 0, 0))
        return b.toByteArray()
    }

    /** (tipo, TTL) de cada registro de las secciones de respuesta, autoridad y adicional. */
    private fun records(r: ByteArray): List<Pair<Int, Long>> {
        var pos = DnsPacket.skipName(r, 12) + 4
        val total = (0 until 3).sumOf { ((r[6 + 2 * it].toInt() and 0xFF) shl 8) or (r[7 + 2 * it].toInt() and 0xFF) }
        val out = ArrayList<Pair<Int, Long>>()
        repeat(total) {
            pos = DnsPacket.skipName(r, pos)
            val type = ((r[pos].toInt() and 0xFF) shl 8) or (r[pos + 1].toInt() and 0xFF)
            var ttl = 0L
            for (i in 0 until 4) ttl = (ttl shl 8) or (r[pos + 4 + i].toLong() and 0xFF)
            val rdlen = ((r[pos + 8].toInt() and 0xFF) shl 8) or (r[pos + 9].toInt() and 0xFF)
            out += type to ttl
            pos += 10 + rdlen
        }
        return out
    }

    private fun id(r: ByteArray) = ((r[0].toInt() and 0xFF) shl 8) or (r[1].toInt() and 0xFF)

    // --- Pruebas --------------------------------------------------------------------------

    @Test
    fun aStoredAnswerIsServedWithTheClientsIdAndQuestion() {
        val c = cache()
        c.store(query("example.com"), response("example.com"))
        val q = query("ExAmPlE.CoM", id = 0xABCD)
        val hit = c.lookup(q)!!
        assertFalse(hit.stale)
        assertEquals(0xABCD, id(hit.response))
        // la pregunta, byte a byte, la del cliente (con sus mayúsculas)
        val end = DnsPacket.parseQuestion(q)!!.end
        assertArrayEquals(q.copyOfRange(12, end), hit.response.copyOfRange(12, end))
        assertEquals(1, c.hits)
        assertEquals(0, c.misses)
    }

    @Test
    fun anUnknownNameIsAMiss() {
        val c = cache()
        assertNull(c.lookup(query("example.com")))
        c.store(query("example.com"), response("example.com"))
        assertNull(c.lookup(query("example.org")))
        assertNull(c.lookup(query("example.com", type = 28)))
        assertEquals(3, c.misses)
    }

    @Test
    fun ttlsAreCountedDownByAge() {
        val c = cache()
        c.store(query("example.com"), response("example.com", listOf(a(60), a(120, 2)), listOf(soa(100, 100))))
        now += 25_900 // 25 s enteros
        val hit = c.lookup(query("example.com"))!!
        assertEquals(listOf(1 to 35L, 1 to 95L, 6 to 75L), records(hit.response))
        now += 100_000 // pasado el TTL de 60 s pero no el de 120: caducada
        assertTrue(c.lookup(query("example.com"))!!.stale)
    }

    @Test
    fun aTtlNeverDropsBelowOne() {
        val c = cache()
        c.store(query("example.com"), response("example.com", listOf(a(60)), listOf(soa(2, 2))))
        now += 50_000
        val hit = c.lookup(query("example.com"))!!
        assertEquals(listOf(1 to 10L, 6 to 1L), records(hit.response))
    }

    @Test
    fun theOptRecordIsNeverRewritten() {
        val c = cache()
        c.store(query("example.com", edns = 1232), response("example.com", opt = true))
        now += 30_000
        var hit = c.lookup(query("example.com", edns = 1232))!!
        assertEquals(listOf(1 to 30L, 41 to 0x8000L), records(hit.response))
        now += 60_000 // ahora caducada: todo a 10 salvo el OPT
        hit = c.lookup(query("example.com", edns = 1232))!!
        assertTrue(hit.stale)
        assertEquals(listOf(1 to 10L, 41 to 0x8000L), records(hit.response))
    }

    @Test
    fun prefetchIsFlaggedNearExpiry() {
        val c = cache()
        c.store(query("example.com"), response("example.com", listOf(a(100))))
        now += 50_000
        assertFalse(c.lookup(query("example.com"))!!.needsRefresh)
        now += 40_000 // quedan 10 s: justo el 10 %, aún no
        assertFalse(c.lookup(query("example.com"))!!.needsRefresh)
        now += 1_000 // quedan 9 s: menos del 10 % (10 s)
        assertTrue(c.lookup(query("example.com"))!!.needsRefresh)
    }

    @Test
    fun shortTtlsUseTheThreeSecondFloor() {
        val c = cache()
        c.store(query("example.com"), response("example.com", listOf(a(20))))
        now += 16_000 // quedan 4 s > 3 s y > 10 % (2 s)
        assertFalse(c.lookup(query("example.com"))!!.needsRefresh)
        now += 2_000 // quedan 2 s < 3 s
        assertTrue(c.lookup(query("example.com"))!!.needsRefresh)
    }

    @Test
    fun anExpiredAnswerIsServedStaleWithShortTtlAndAsksForRefresh() {
        val c = cache()
        c.store(query("example.com"), response("example.com", listOf(a(30), a(300, 2))))
        now += 31_000
        val hit = c.lookup(query("example.com", id = 0x4242))!!
        assertTrue(hit.stale)
        assertTrue(hit.needsRefresh)
        assertEquals(0x4242, id(hit.response))
        assertEquals(listOf(1 to 10L, 1 to 10L), records(hit.response))
        assertEquals(1, c.staleHits)
    }

    @Test
    fun staleAnswersExpireAfterMaxStale() {
        val c = cache(maxStaleMs = 60_000)
        c.store(query("example.com"), response("example.com", listOf(a(30))))
        now += 30_000 + 59_000
        assertTrue(c.lookup(query("example.com"))!!.stale)
        now += 2_000
        assertNull(c.lookup(query("example.com")))
        assertEquals(0, c.size) // y se tira
    }

    @Test
    fun negativeAnswersUseTheSoaTtlClamped() {
        val c = cache()
        // min(TTL del registro, MINIMUM) = 40
        c.store(query("a.example.com"), response("a.example.com", emptyList(), listOf(soa(90, 40)), rcode = 3))
        // MINIMUM mayor que el TTL del registro: manda el registro; y 5 s es el suelo
        c.store(query("b.example.com"), response("b.example.com", emptyList(), listOf(soa(2, 900))))
        // 300 s es el techo
        c.store(query("c.example.com"), response("c.example.com", emptyList(), listOf(soa(9000, 9000)), rcode = 3))
        // sin SOA: 30 s
        c.store(query("d.example.com"), response("d.example.com", emptyList()))

        now += 39_000
        assertNotNull(c.lookup(query("a.example.com")))
        now += 2_000
        assertNull(c.lookup(query("a.example.com")))

        now += 0
        assertNull("b ya pasó de 5 s", c.lookup(query("b.example.com")))
        assertNull("d ya pasó de 30 s", c.lookup(query("d.example.com")))
        assertNotNull("c vive 300 s", c.lookup(query("c.example.com")))
        now += 260_000 // 301 s desde el principio
        assertNull(c.lookup(query("c.example.com")))
    }

    @Test
    fun negativeAnswersAreNeverServedStaleNorPrefetched() {
        val c = cache()
        c.store(query("n.example.com"), response("n.example.com", emptyList(), listOf(soa(100, 100)), rcode = 3))
        now += 99_000 // casi caducada: las negativas no se renuevan por adelantado
        val hit = c.lookup(query("n.example.com"))!!
        assertFalse(hit.stale)
        assertFalse(hit.needsRefresh)
        now += 2_000
        assertNull(c.lookup(query("n.example.com")))
    }

    @Test
    fun nodataWithoutSoaIsCachedThirtySeconds() {
        val c = cache()
        c.store(query("example.com", type = 28), response("example.com", emptyList(), type = 28))
        now += 29_000
        assertNotNull(c.lookup(query("example.com", type = 28)))
        now += 2_000
        assertNull(c.lookup(query("example.com", type = 28)))
    }

    @Test
    fun uncacheableResponsesAreNotStored() {
        val c = cache()
        val q = query("example.com")
        c.store(q, response("example.com", listOf(a(0))))                       // TTL 0
        c.store(q, response("example.com", tc = true))                          // cortada
        c.store(q, response("example.com", emptyList(), rcode = 2))             // SERVFAIL
        c.store(q, response("example.com", emptyList(), rcode = 5))             // REFUSED
        c.store(q, response("other.com", qname = "other.com"))                  // otra pregunta
        c.store(q, q)                                                           // ni es respuesta
        c.store(query("example.com", opcode = 4), response("example.com"))      // opcode NOTIFY
        assertEquals(0, c.size)
        assertNull(c.lookup(q))
    }

    @Test
    fun theMinimumTtlOfTheAnswerSectionIsUsedAndCapped() {
        val c = cache()
        c.store(query("a.example.com"), response("a.example.com", listOf(a(500), a(20, 2))))
        now += 21_000
        assertTrue(c.lookup(query("a.example.com"))!!.stale)

        c.store(query("b.example.com"), response("b.example.com", listOf(a(10_000_000))))
        now += 86_399_000
        assertFalse(c.lookup(query("b.example.com"))!!.stale)
        now += 2_000
        assertTrue(c.lookup(query("b.example.com"))!!.stale)
    }

    @Test
    fun theOldestEntryIsEvictedBeyondMaxEntries() {
        val c = cache(maxEntries = 2)
        c.store(query("a.com"), response("a.com"))
        c.store(query("b.com"), response("b.com"))
        assertNotNull(c.lookup(query("a.com"))) // a pasa a ser la más reciente
        c.store(query("c.com"), response("c.com"))
        assertEquals(2, c.size)
        assertNull(c.lookup(query("b.com")))
        assertNotNull(c.lookup(query("a.com")))
        assertNotNull(c.lookup(query("c.com")))
    }

    @Test
    fun aResponseBiggerThanTheClientAcceptsIsAMiss() {
        val c = cache()
        val big = response("example.com", List(40) { a(60, it) }) // pasa de 512 bytes
        assertTrue(big.size > 512)
        c.store(query("example.com", edns = 4096), big)
        assertNull(c.lookup(query("example.com")))            // sin EDNS: 512
        assertNull(c.lookup(query("example.com", edns = 600)))
        assertNotNull(c.lookup(query("example.com", edns = 1232)))
    }

    @Test
    fun malformedInputNeverThrows() {
        val c = cache()
        val good = response("example.com")
        c.store(query("example.com"), good)
        for (n in 0..good.size) {
            c.store(query("example.com"), good.copyOf(n))
            c.lookup(good.copyOf(n))
        }
        // contadores de registros que mienten, punteros que se apuntan a sí mismos, rdlength enorme
        val lying = good.copyOf().also { it[7] = 50 }
        c.store(query("lying.com"), lying)
        val loop = good.copyOf().also { it[good.size - 16] = 0xC0.toByte(); it[good.size - 15] = (good.size - 16).toByte() }
        c.store(query("example.com"), loop)
        val rdlen = good.copyOf().also { it[good.size - 5] = 0x7F }
        c.store(query("example.com"), rdlen)
        c.lookup(ByteArray(0))
        c.lookup(ByteArray(11))
        c.store(ByteArray(0), ByteArray(0))
        val rnd = java.util.Random(7)
        repeat(500) {
            val junk = ByteArray(rnd.nextInt(80)).also { rnd.nextBytes(it) }
            c.store(query("example.com"), junk)
            c.lookup(junk)
        }
        assertNotNull(c.lookup(query("example.com"))) // lo bueno sigue ahí o se cambió por algo válido
    }
}
