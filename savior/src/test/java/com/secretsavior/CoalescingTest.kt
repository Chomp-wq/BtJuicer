package com.secretsavior

import com.secretsavior.vpn.DnsForwarder
import com.secretsavior.vpn.DnsPacket
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Consultas idénticas en vuelo, paquetes por consulta y retraso adaptativo. */
class CoalescingTest {

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { runCatching { it.close() } }

    private fun srv(delayMs: Long = 0, silent: Boolean = false) = Srv(silent = silent, delayMs = delayMs).also { closeables += it }

    private fun fwd(primaries: List<Srv>, fallbacks: List<Srv> = emptyList(), escalate: Long? = 5_000, giveUp: Long = 10_000) =
        DnsForwarder(primaries.map { it.address }, fallbacks.map { it.address }, protect = {}, cache = null, escalateAfterMs = escalate, giveUpAfterMs = giveUp)
            .also { closeables += it }

    private fun many(f: DnsForwarder, queries: List<ByteArray>): Map<Int, ByteArray?> {
        val latch = CountDownLatch(queries.size)
        val out = ConcurrentHashMap<Int, ByteArray?>()
        for (q in queries) {
            val id = ((q[0].toInt() and 0xFF) shl 8) or (q[1].toInt() and 0xFF)
            f.query(q) { out[id] = it ?: byteArrayOf(); latch.countDown() }
        }
        assertTrue(latch.await(30, TimeUnit.SECONDS))
        return out
    }

    @Test
    fun identicalQueriesInFlightAreSentOnceAndEachGetsItsOwnIdAndCasing() {
        val s = srv(delayMs = 1_000) // sigue en vuelo cuando entran las demás
        val f = fwd(listOf(s))
        val qs = listOf(dnsQuery("Example.COM", 0x1111), dnsQuery("eXaMpLe.com", 0x2222), dnsQuery("EXAMPLE.com", 0x3333))
        val r = many(f, qs)
        assertEquals("una sola salida a la red", 1, s.received.get())
        for (q in qs) {
            val id = ((q[0].toInt() and 0xFF) shl 8) or (q[1].toInt() and 0xFF)
            val resp = r[id]!!
            assertEquals(id, ((resp[0].toInt() and 0xFF) shl 8) or (resp[1].toInt() and 0xFF))
            val end = DnsPacket.parseQuestion(q)!!.end
            assertArrayEquals("su pregunta, con sus mayúsculas", q.copyOfRange(12, end), resp.copyOfRange(12, end))
            assertEquals("1.1.1.1", ipOfAnswer(resp))
        }
    }

    @Test
    fun differentTypeOrDifferentEdnsIsNotCoalesced() {
        val s = srv(delayMs = 1_000)
        val f = fwd(listOf(s))
        many(f, listOf(dnsQuery("example.com", 1), dnsQuery("example.com", 2, type = 28)))
        assertEquals(2, s.received.get())
        val s2 = srv(delayMs = 1_000)
        many(fwd(listOf(s2)), listOf(dnsQuery("example.com", 1), dnsQuery("example.com", 2, edns = 1232)))
        assertEquals(2, s2.received.get())
    }

    @Test
    fun coalescingIsBounded() {
        val s = srv(delayMs = 1_000)
        val f = fwd(listOf(s))
        val r = many(f, (1..(DnsForwarder.MAX_WAITERS + 6)).map { dnsQuery("example.com", it) })
        assertEquals("todas contestadas", DnsForwarder.MAX_WAITERS + 6, r.size)
        assertTrue(r.values.all { it != null && it.isNotEmpty() })
        assertEquals("la primera tanda y una más para el resto", 2, s.received.get())
    }

    @Test
    fun afterTheAnswerANewQueryGoesToTheNetworkAgain() {
        val s = srv()
        val f = fwd(listOf(s))
        many(f, listOf(dnsQuery("example.com", 1)))
        many(f, listOf(dnsQuery("example.com", 2)))
        assertEquals(2, s.received.get())
    }

    @Test
    fun whenTheCoalescedQueryFailsEveryWaiterGetsNull() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), giveUp = 1_500)
        val r = many(f, listOf(dnsQuery("example.com", 1), dnsQuery("example.com", 2)))
        assertEquals(1, s.received.get())
        assertTrue(r.values.all { it!!.isEmpty() })
    }

    // --- Paquetes por consulta ------------------------------------------------------------

    @Test
    fun aQueryGoesToTheTwoBestPrimariesNotAllFour() {
        val servers = List(4) { srv() }
        val f = fwd(servers)
        many(f, listOf(dnsQuery("example.com", 1)))
        Thread.sleep(100)
        assertEquals(2, servers.sumOf { it.received.get() })
    }

    @Test
    fun theRestJoinAfterTheHedgeDelay() {
        val slow = List(2) { srv(silent = true) }
        val good = List(2) { srv() }
        val f = fwd(slow + good, escalate = 150)
        val t0 = System.nanoTime()
        val r = many(f, listOf(dnsQuery("example.com", 1)))
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertNotNull(r[1])
        assertTrue("contestó tras el retraso: $ms ms", ms >= 130) // sólo pudieron contestar los dos que entran tras la espera
        assertEquals(1, good[0].received.get())
        assertEquals(1, good[1].received.get())
    }

    @Test
    fun theDefaultHedgeIsAdaptiveWhenNothingHasBeenMeasured() {
        val f = fwd(listOf(srv(silent = true)), fallbacks = listOf(srv()), escalate = null)
        val t0 = System.nanoTime()
        assertNotNull(many(f, listOf(dnsQuery("example.com", 1)))[1])
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("sin medir: ~300 ms, fue $ms", ms in 250..2_500)
    }
}
