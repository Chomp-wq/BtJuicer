package com.secretsavior

import com.secretsavior.vpn.DnsForwarder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ForwarderTest {

    /** Un resolutor de mentira: contesta con la misma consulta y el bit de respuesta puesto. */
    private class FakeDns(val delayMs: Long = 0, val silent: Boolean = false) : AutoCloseable {
        val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
        val address = InetSocketAddress(InetAddress.getLoopbackAddress(), socket.localPort)
        val received = AtomicInteger()
        private val delayer = Executors.newSingleThreadScheduledExecutor()
        private val thread = Thread {
            val buf = ByteArray(4096)
            while (!socket.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                try {
                    socket.receive(p)
                } catch (e: Exception) {
                    break
                }
                received.incrementAndGet()
                if (silent) continue
                val reply = buf.copyOf(p.length).also { it[2] = (it[2].toInt() or 0x80).toByte() }
                val to = p.socketAddress
                delayer.schedule({ runCatching { socket.send(DatagramPacket(reply, reply.size, to)) } }, delayMs, TimeUnit.MILLISECONDS)
            }
        }.apply { isDaemon = true; start() }

        override fun close() {
            socket.close()
            delayer.shutdownNow()
        }
    }

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { it.close() }

    private fun fake(delayMs: Long = 0, silent: Boolean = false) = FakeDns(delayMs, silent).also { closeables += it }

    private fun forwarder(primaries: List<FakeDns>, fallbacks: List<FakeDns>) =
        DnsForwarder(primaries.map { it.address }, fallbacks.map { it.address }, protect = {}, escalateAfterMs = 150, giveUpAfterMs = 600)
            .also { closeables += it }

    private fun query(id: Int) = byteArrayOf((id shr 8).toByte(), id.toByte(), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1)

    private fun ask(f: DnsForwarder, id: Int, timeoutMs: Long = 2_000): ByteArray? {
        val latch = CountDownLatch(1)
        var result: ByteArray? = null
        f.query(query(id)) { result = it; latch.countDown() }
        assertTrue("sin llamada de vuelta", latch.await(timeoutMs, TimeUnit.MILLISECONDS))
        return result
    }

    @Test
    fun answersAndRestoresTheOriginalId() {
        val f = forwarder(listOf(fake(), fake()), listOf(fake()))
        val r = ask(f, 0x1234)!!
        assertEquals(0x12, r[0].toInt())
        assertEquals(0x34, r[1].toInt())
        assertTrue("es una respuesta", r[2].toInt() and 0x80 != 0)
    }

    @Test
    fun asksBothPrimariesAtOnceAndCallsBackOnce() {
        val a = fake()
        val b = fake()
        val f = forwarder(listOf(a, b), listOf(fake()))
        val calls = AtomicInteger()
        val latch = CountDownLatch(1)
        f.query(query(7)) { calls.incrementAndGet(); latch.countDown() }
        assertTrue(latch.await(1, TimeUnit.SECONDS))
        Thread.sleep(200) // la segunda respuesta llega y se descarta
        assertEquals(1, calls.get())
        assertEquals(1, a.received.get())
        assertEquals(1, b.received.get())
    }

    @Test
    fun fallsBackWhenPrimariesAreSilent() {
        val fallback = fake()
        val f = forwarder(listOf(fake(silent = true), fake(silent = true)), listOf(fallback))
        val start = System.nanoTime()
        assertNotNull(ask(f, 1))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertTrue("tardó $ms ms", ms in 100..590)
        assertEquals(1, fallback.received.get())
    }

    @Test
    fun givesUpWithNullWhenNobodyAnswers() {
        val f = forwarder(listOf(fake(silent = true)), listOf(fake(silent = true)))
        assertNull(ask(f, 2))
    }

    @Test
    fun aSlowLookupDoesNotHoldUpTheOthers() {
        // 300 consultas a la vez contra un resolutor que tarda 100 ms en cada una. Con un
        // hilo bloqueado por consulta y seis hilos, esto tardaba más de 5 s.
        val f = forwarder(listOf(fake(delayMs = 100)), listOf(fake()))
        val latch = CountDownLatch(300)
        val ok = AtomicInteger()
        val start = System.nanoTime()
        repeat(300) { i -> f.query(query(i)) { if (it != null) ok.incrementAndGet(); latch.countDown() } }
        assertTrue(latch.await(3, TimeUnit.SECONDS))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertEquals(300, ok.get())
        assertTrue("tardó $ms ms", ms < 2_000)
    }

    @Test
    fun ignoresAnswersFromStrangers() {
        val f = forwarder(listOf(fake(silent = true)), listOf(fake(silent = true)))
        val latch = CountDownLatch(1)
        var result: ByteArray? = byteArrayOf()
        f.query(query(9)) { result = it; latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))
        assertNull("sólo cuenta lo que llega de un resolutor conocido", result)
    }
}
