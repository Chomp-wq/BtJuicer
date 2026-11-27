package com.secretsavior

import com.secretsavior.vpn.DnsForwarder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Atasco aguas arriba: detección, reinicio del camino, aviso a Android y DNS sobre TLS de reserva. */
class StallRecoveryTest {

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { runCatching { it.close() } }

    private fun srv(silent: Boolean = false) = Srv(silent = silent).also { closeables += it }

    private fun fwd(
        s: List<Srv>,
        stallQueries: Int = 6,
        onStall: () -> Unit = {},
        dot: ((((ByteArray, InetSocketAddress) -> Unit)) -> com.secretsavior.vpn.DotTransport)? = null,
        dotProbeMs: Long = 30_000,
        protect: (DatagramSocket) -> Unit = {},
    ) = DnsForwarder(
        s.map { it.address }, emptyList(), protect = protect, cache = null,
        escalateAfterMs = 5_000, giveUpAfterMs = 300, // sin escalada: cada consulta caduca a los 300 ms
        stallQueries = stallQueries, onStall = onStall, dot = dot, dotProbeMs = dotProbeMs,
    ).also { closeables += it }

    private fun waitFor(timeoutMs: Long = 3_000, what: String = "condición", cond: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!cond() && System.nanoTime() < end) Thread.sleep(10)
        assertTrue("$what no se cumplió a tiempo", cond())
    }

    private var seq = 0

    /** [n] consultas de nombres distintos a la vez; espera a que todas terminen y devuelve sus resultados. */
    private fun burst(f: DnsForwarder, n: Int): List<ByteArray?> {
        val latch = CountDownLatch(n)
        val out = CopyOnWriteArrayList<ByteArray?>()
        repeat(n) { f.query(dnsQuery("q${seq++}.example", it + 1)) { r -> out += r; latch.countDown() } }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        return out
    }

    private fun ask(f: DnsForwarder, name: String, timeoutMs: Long = 3_000): Pair<ByteArray?, Long> {
        val latch = CountDownLatch(1)
        var r: ByteArray? = null
        val t0 = System.nanoTime()
        f.query(dnsQuery(name, 99)) { r = it; latch.countDown() }
        assertTrue(latch.await(timeoutMs, TimeUnit.MILLISECONDS))
        return r to (System.nanoTime() - t0) / 1_000_000
    }

    @Test
    fun sixSilentQueriesAreOneStallWithAFreshSocketAndACallback() {
        val s = srv(silent = true)
        val calls = AtomicInteger()
        val f = fwd(listOf(s), onStall = { calls.incrementAndGet() })
        val port = f.currentSocket().localPort
        val results = burst(f, 6)
        assertTrue(results.all { it == null })
        waitFor(what = "el aviso") { calls.get() == 1 }
        assertEquals(1, f.stallRecoveries)
        assertFalse("socket nuevo", port == f.currentSocket().localPort)
        Thread.sleep(200)
        assertEquals("una sola vez", 1, calls.get())
    }

    @Test
    fun fiveSilentQueriesAreNotAStall() {
        val s = srv(silent = true)
        val calls = AtomicInteger()
        val f = fwd(listOf(s), onStall = { calls.incrementAndGet() })
        burst(f, 5)
        Thread.sleep(100)
        assertEquals(0, calls.get())
        assertEquals(0, f.stallRecoveries)
    }

    @Test
    fun anAnswerInTheMiddleCutsTheStreak() {
        val s = srv(silent = true)
        val calls = AtomicInteger()
        val f = fwd(listOf(s), onStall = { calls.incrementAndGet() })
        burst(f, 3)
        s.silent = false
        assertNotNull(ask(f, "alive.example").first)
        s.silent = true
        burst(f, 3)
        Thread.sleep(100)
        assertEquals(0, calls.get())
    }

    @Test
    fun theSocketIsRebuiltAndInFlightQueriesAreResentAfterAStall() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), onStall = { s.silent = false }) // el «atasco» se acaba con el socket nuevo
        val late = CountDownLatch(1)
        var lateAnswer: ByteArray? = byteArrayOf()
        val first = CountDownLatch(6)
        repeat(6) { f.query(dnsQuery("a$it.example", it + 1)) { first.countDown() } }
        Thread.sleep(150)
        // sale a los 150 ms y caduca a los 450: el atasco (a los 300) la pilla en vuelo
        f.query(dnsQuery("inflight.example", 77)) { lateAnswer = it; late.countDown() }
        assertTrue(late.await(3, TimeUnit.SECONDS))
        assertNotNull("el reenvío tras el atasco la contestó", lateAnswer)
        assertTrue(first.await(3, TimeUnit.SECONDS))
        assertEquals("salió, se calló y se reenvió", 2, s.names.count { it == "inflight.example" })
    }

    @Test
    fun aCallbackThatThrowsDoesNotBreakTheForwarder() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), onStall = { throw IllegalStateException("fallo del aviso") })
        burst(f, 6)
        waitFor(what = "el atasco") { f.stallRecoveries == 1 }
        s.silent = false
        assertNotNull(ask(f, "after.example").first)
    }

    @Test
    fun aSocketThatCannotBeRebuiltDoesNotKillTheForwarder() {
        val s = srv(silent = true)
        val protects = AtomicInteger()
        // el primer socket va bien; los siguientes lanzan, hasta con un Error
        val f = fwd(listOf(s), protect = { if (protects.incrementAndGet() > 1) throw IllegalStateException("protect") })
        burst(f, 6)
        waitFor(what = "el atasco") { f.stallRecoveries == 1 }
        s.silent = false
        assertNotNull("sigue con el socket que tenía", ask(f, "still.example").first)
    }

    @Test
    fun aStallClearsTheDownBackoffSoQueriesGoToTheBestTwoAgain() {
        val servers = List(4) { srv(silent = true) }
        // escalada a los 100 ms: tres seguidas marcan los primarios como caídos (a todos desde el principio)
        val f = DnsForwarder(
            servers.map { it.address }, emptyList(), protect = {}, cache = null,
            escalateAfterMs = 100, giveUpAfterMs = 900, stallQueries = 3,
        ).also { closeables += it }
        val done = CountDownLatch(3)
        repeat(3) { f.query(dnsQuery("d$it.example", it + 1)) { done.countDown() } }
        Thread.sleep(300) // las tres ya escalaron: primarios caídos
        val before = servers.sumOf { it.received.get() }
        f.query(dnsQuery("down.example", 50)) { }
        Thread.sleep(40)
        assertEquals("caídos: a los cuatro", 4, servers.sumOf { it.received.get() } - before)
        assertTrue(done.await(3, TimeUnit.SECONDS))
        waitFor(what = "el atasco") { f.stallRecoveries >= 1 }
        Thread.sleep(950) // que caduquen y escalen las que estaban en vuelo
        val before2 = servers.sumOf { it.received.get() }
        f.query(dnsQuery("up.example", 51)) { }
        Thread.sleep(40)
        assertEquals("tras el atasco: a los dos mejores", 2, servers.sumOf { it.received.get() } - before2)
    }

    // --- DNS sobre TLS de reserva ---------------------------------------------------------

    private class DotHolder {
        @Volatile
        var dot: FakeDot? = null
    }

    @Test
    fun aPersistentStallMovesDnsToTlsAndAnAnswerOverUdpMovesItBack() {
        val s = srv(silent = true)
        val h = DotHolder()
        val f = fwd(
            listOf(s), stallQueries = 3, dotProbeMs = 250,
            dot = { m -> FakeDot(m, delayMs = 400).also { h.dot = it; closeables += it } },
        )
        burst(f, 3)
        waitFor(what = "el primer atasco") { f.stallRecoveries == 1 }
        assertFalse("un solo atasco no basta", f.usingDot)
        burst(f, 3)
        waitFor(what = "el segundo atasco") { f.stallRecoveries == 2 }
        assertTrue(f.usingDot)

        // en modo DoT las consultas van por TLS, no por UDP
        val udpBefore = s.received.get()
        h.dot!!.delayMs = 0
        val (r, ms) = ask(f, "viadot.example")
        assertNotNull(r)
        assertEquals("9.9.9.9", ipOfAnswer(r!!))
        assertTrue("$ms ms", ms < 250)
        assertEquals("sin tocar el UDP (aún no toca sondeo)", udpBefore, s.received.get())

        // el UDP vuelve: el siguiente sondeo lo ve contestar y se sale del modo
        h.dot!!.delayMs = 600
        s.silent = false
        Thread.sleep(300) // toca sondeo
        val (r2, _) = ask(f, "probe.example")
        assertNotNull(r2)
        assertEquals("1.1.1.1", ipOfAnswer(r2!!)) // ganó el UDP (la del sondeo), no el TLS lento
        assertFalse(f.usingDot)
        assertTrue(h.dot!!.disconnects.get() >= 1)
    }

    @Test
    fun anAnswerBetweenStallsPreventsTheTlsFallback() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), stallQueries = 3, dot = { m -> FakeDot(m).also { closeables += it } })
        burst(f, 3)
        waitFor(what = "el primer atasco") { f.stallRecoveries == 1 }
        s.silent = false
        assertNotNull(ask(f, "alive.example").first)
        s.silent = true
        burst(f, 3)
        waitFor(what = "el segundo atasco") { f.stallRecoveries == 2 }
        assertFalse(f.usingDot)
    }

    @Test
    fun aNetworkChangeLeavesTlsMode() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), stallQueries = 3, dot = { m -> FakeDot(m).also { closeables += it } })
        burst(f, 3)
        waitFor { f.stallRecoveries == 1 }
        burst(f, 3)
        waitFor { f.usingDot }
        f.onNetworkChanged()
        assertFalse(f.usingDot)
    }

    @Test
    fun ifTlsCannotTakeTheQueryItFallsBackToUdp() {
        val s = srv(silent = true)
        val h = DotHolder()
        val f = fwd(listOf(s), stallQueries = 3, dot = { m -> FakeDot(m).also { h.dot = it; closeables += it } })
        burst(f, 3)
        waitFor { f.stallRecoveries == 1 }
        burst(f, 3)
        waitFor { f.usingDot }
        h.dot!!.accepting = false // cola llena / sin conexión
        s.silent = false
        val (r, _) = ask(f, "udp.example")
        assertEquals("1.1.1.1", ipOfAnswer(r!!))
    }

    @Test
    fun noTlsTransportMeansTheStallOnlyRebuildsTheSocket() {
        val s = srv(silent = true)
        val f = fwd(listOf(s), stallQueries = 3)
        repeat(3) { burst(f, 3) }
        assertFalse(f.usingDot)
        assertNull(ask(f, "x.example").first)
    }
}
