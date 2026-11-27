package com.secretsavior

import com.secretsavior.vpn.DnsCache
import com.secretsavior.vpn.DnsForwarder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Primero lo fresco (RFC 8767, modelo del cliente) y calentamiento tras un cambio de red. */
class FreshFirstTest {

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { runCatching { it.close() } }

    private fun srv(delayMs: Long = 0, ttl: Int = 30) = Srv(delayMs = delayMs, ttl = ttl).also { closeables += it }

    private fun fwd(s: Srv, cache: DnsCache?, staleMs: Long = 500, giveUp: Long = 3_000, warm: Int = 20) =
        DnsForwarder(
            listOf(s.address), emptyList(), protect = {}, cache = cache,
            escalateAfterMs = 5_000, giveUpAfterMs = giveUp, staleFallbackMs = staleMs, warmUpCount = warm,
        ).also { closeables += it }

    private class Answer(val response: ByteArray?, val ms: Long)

    private fun ask(f: DnsForwarder, name: String, id: Int = 1, timeoutMs: Long = 20_000): Answer {
        val latch = CountDownLatch(1)
        var r: ByteArray? = null
        val t0 = System.nanoTime()
        f.query(dnsQuery(name, id)) { r = it; latch.countDown() }
        assertTrue("sin respuesta", latch.await(timeoutMs, TimeUnit.MILLISECONDS))
        return Answer(r, (System.nanoTime() - t0) / 1_000_000)
    }

    private fun ttlOf(r: ByteArray) = ((r[r.size - 10].toInt() and 0xFF) shl 24) or ((r[r.size - 9].toInt() and 0xFF) shl 16) or
        ((r[r.size - 8].toInt() and 0xFF) shl 8) or (r[r.size - 7].toInt() and 0xFF)

    // El plazo es una red de seguridad (CI lenta); se espera por eventos.
    private fun waitFor(timeoutMs: Long = 20_000, cond: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!cond() && System.nanoTime() < end) Thread.sleep(10)
        assertTrue("condición no cumplida a tiempo", cond())
    }

    @Test
    fun anExpiredEntryGoesToTheNetworkAndTheFreshAnswerWins() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }))
        assertEquals("1.1.1.1", ipOfAnswer(ask(f, "example.com").response!!))
        clock += 60_000 // caducada hace 30 s
        s.ip = byteArrayOf(2, 2, 2, 2)
        s.delayMs = 300
        val a = ask(f, "example.com", id = 2)
        assertEquals("la fresca, no la caducada", "2.2.2.2", ipOfAnswer(a.response!!))
        assertTrue("esperó a la red: ${a.ms} ms", a.ms >= 280)
        assertEquals(2, s.received.get())
        assertEquals(2, ((a.response[0].toInt() and 0xFF) shl 8) or (a.response[1].toInt() and 0xFF))
    }

    @Test
    fun ifTheNetworkIsSlowTheStaleOneIsServedAfterTheFallbackTimeout() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), staleMs = 150, giveUp = 15_000)
        assertEquals("1.1.1.1", ipOfAnswer(ask(f, "example.com").response!!))
        clock += 60_000
        s.ip = byteArrayOf(2, 2, 2, 2)
        s.delayMs = 3_000 // la red tarda mucho más que la espera por la caducada
        val a = ask(f, "example.com", id = 3)
        assertEquals("1.1.1.1", ipOfAnswer(a.response!!))
        assertEquals("con el TTL corto de las caducadas", 10, ttlOf(a.response))
        // sirvió la caducada sin esperar a la red (que tarda 3 s); la cota inferior es la espera configurada
        assertTrue("tardó ${a.ms} ms", a.ms in 120..2_500)
        // la consulta siguió y renovó la caché: la próxima ya es la nueva y no sale a la red
        waitFor { s.received.get() == 2 }
        var again = ask(f, "example.com", id = 4)
        // la renovación llega a los 3 s; hasta entonces la caché sigue caducada (se sirve la caducada)
        val limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (ipOfAnswer(again.response!!) != "2.2.2.2" && System.nanoTime() < limit) {
            Thread.sleep(200)
            again = ask(f, "example.com", id = 4)
        }
        assertEquals("2.2.2.2", ipOfAnswer(again.response!!))
        val sent = s.received.get()
        ask(f, "example.com", id = 5)
        assertEquals("ya renovada: no sale a la red", sent, s.received.get())
    }

    @Test
    fun aQueryThatGivesUpServesTheStaleOneInsteadOfServfail() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), staleMs = 30_000, giveUp = 400)
        ask(f, "example.com")
        clock += 60_000
        s.silent = true
        val a = ask(f, "example.com", id = 5)
        assertNotNull("sin la caducada habría sido null (SERVFAIL)", a.response)
        assertEquals("1.1.1.1", ipOfAnswer(a.response!!))
        assertTrue("a los ${a.ms} ms", a.ms >= 350) // esperó al abandono, no a la espera de la caducada
    }

    @Test
    fun anUpstreamServfailServesTheStaleOne() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), staleMs = 15_000)
        ask(f, "example.com")
        clock += 60_000
        s.servfail = true
        val a = ask(f, "example.com", id = 6)
        assertEquals("1.1.1.1", ipOfAnswer(a.response!!))
        assertTrue("no esperó a la espera por la caducada: ${a.ms} ms", a.ms < 10_000)
    }

    @Test
    fun withoutAStaleEntryAServfailIsDeliveredAsIs() {
        val s = srv()
        s.servfail = true
        val a = ask(fwd(s, DnsCache()), "example.com", id = 7)
        assertEquals(2, a.response!![3].toInt() and 0xF)
    }

    @Test
    fun nothingStaleAndNoAnswerStillGivesNull() {
        val s = srv()
        s.silent = true
        assertNull(ask(fwd(s, DnsCache(), giveUp = 300), "example.com").response)
    }

    @Test
    fun aFreshEntryAboutToExpireIsAnsweredAtOnceAndRefreshedOnce() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), giveUp = 15_000)
        ask(f, "example.com")
        clock += 28_000 // quedan 2 s de 30: a punto de caducar
        s.ip = byteArrayOf(3, 3, 3, 3)
        s.delayMs = 3_000
        val a = ask(f, "example.com", id = 8)
        assertEquals("1.1.1.1", ipOfAnswer(a.response!!))
        assertTrue("al momento: ${a.ms} ms", a.ms < 2_000) // la red tarda 3 s
        ask(f, "example.com", id = 9) // otra mientras se renueva: no lanza otra renovación
        waitFor { s.received.get() >= 2 }
        // mientras la renovación sigue en vuelo, preguntar de nuevo no lanza otra; al llegar, la caché es la nueva
        var last = ask(f, "example.com", id = 10)
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (ipOfAnswer(last.response!!) != "3.3.3.3" && System.nanoTime() < end) {
            Thread.sleep(250)
            last = ask(f, "example.com", id = 10)
        }
        assertEquals("3.3.3.3", ipOfAnswer(last.response!!))
        assertEquals("una sola renovación", 2, s.received.get())
    }

    @Test
    fun forgettingStaleOnANetworkChangeStillHolds() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), giveUp = 300)
        ask(f, "example.com")
        clock += 60_000
        s.silent = true
        f.onNetworkChanged() // lo que contestó la red anterior no se sirve caducado
        assertNull(ask(f, "example.com", id = 11).response)
    }

    @Test
    fun stalesServedCountAsCacheAnswers() {
        val s = srv()
        var clock = 0L
        val f = fwd(s, DnsCache(clock = { clock }), giveUp = 300, staleMs = 100)
        ask(f, "example.com")
        clock += 60_000
        s.silent = true
        ask(f, "example.com", id = 12)
        assertEquals("sólo cuenta la caducada que se sirvió de verdad", 1, f.cacheHits)
        assertEquals(2, f.cacheLookups)
    }

    // --- Calentamiento tras cambiar de red -------------------------------------------------

    @Test
    fun aNetworkChangeRefreshesTheHottestEntriesThroughTheForwarder() {
        val s = srv(ttl = 300)
        val f = fwd(s, DnsCache())
        repeat(3) { ask(f, "hot1.example", id = 20 + it) }
        repeat(2) { ask(f, "hot2.example", id = 30 + it) }
        ask(f, "cold.example", id = 40)
        assertEquals(3, s.received.get())
        val socketBefore = f.currentSocket().localPort

        f.onNetworkChanged()
        waitFor { s.received.get() == 5 }
        Thread.sleep(150)
        assertEquals("sólo las dos con uso", 5, s.received.get())
        assertEquals(listOf("hot1.example", "hot2.example"), s.names.toList().takeLast(2).sorted())
        assertFalse(socketBefore == f.currentSocket().localPort)
        // la renovación quedó en la caché: lo siguiente no sale a la red
        ask(f, "hot1.example", id = 50)
        assertEquals("salió de la caché, no a la red", 5, s.received.get())
    }

    @Test
    fun warmUpIsBoundedByTheConfiguredCount() {
        val s = srv(ttl = 300)
        val f = fwd(s, DnsCache(), warm = 1)
        repeat(4) { ask(f, "hot1.example", id = 60 + it) }
        repeat(2) { ask(f, "hot2.example", id = 70 + it) }
        assertEquals(2, s.received.get())
        f.onNetworkChanged()
        waitFor { s.received.get() == 3 }
        Thread.sleep(150)
        assertEquals(3, s.received.get())
        assertEquals("hot1.example", s.names.last())
    }

    @Test
    fun withoutACacheANetworkChangeWarmsNothingAndDoesNotFail() {
        val s = srv()
        val f = fwd(s, null)
        ask(f, "example.com")
        f.onNetworkChanged()
        Thread.sleep(100)
        assertEquals(1, s.received.get())
        assertNotNull(ask(f, "example.com", id = 2).response) // sigue contestando con el socket nuevo
    }
}
