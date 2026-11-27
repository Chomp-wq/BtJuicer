package com.secretsavior

import com.secretsavior.vpn.DnsForwarder
import com.secretsavior.vpn.DotFraming
import com.secretsavior.vpn.TlsDotTransport
import com.secretsavior.vpn.TunnelRecovery
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class DotTest {

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { runCatching { it.close() } }

    private fun q(name: String, id: Int) = dnsQuery(name, id)

    // --- Formato -------------------------------------------------------------------------

    @Test
    fun aFrameIsLengthPrefixed() {
        val m = q("example.com", 5)
        val f = DotFraming.frame(m)
        assertEquals(m.size, ((f[0].toInt() and 0xFF) shl 8) or (f[1].toInt() and 0xFF))
        assertArrayEquals(m, f.copyOfRange(2, f.size))
    }

    @Test
    fun theDeframerReassemblesMessagesFromAnyChunking() {
        val a = q("a.example", 1)
        val b = q("bb.example", 2)
        val stream = DotFraming.frame(a) + DotFraming.frame(b)
        for (chunk in listOf(1, 2, 3, 7, stream.size)) {
            val d = DotFraming.Deframer()
            val out = ArrayList<ByteArray>()
            var i = 0
            while (i < stream.size) {
                val n = minOf(chunk, stream.size - i)
                out += d.feed(stream, i, n)
                i += n
            }
            assertEquals("troceado en $chunk", 2, out.size)
            assertArrayEquals(a, out[0])
            assertArrayEquals(b, out[1])
        }
    }

    @Test
    fun severalMessagesInOneReadAndAPartialTailAreKept() {
        val a = q("a.example", 1)
        val b = q("b.example", 2)
        val s = DotFraming.frame(a) + DotFraming.frame(b)
        val d = DotFraming.Deframer()
        val first = d.feed(s, 0, s.size - 3)
        assertEquals(1, first.size)
        val rest = d.feed(s, s.size - 3, 3)
        assertEquals(1, rest.size)
        assertArrayEquals(b, rest[0])
    }

    @Test
    fun aBrokenStreamIsAnError() {
        val d = DotFraming.Deframer()
        try {
            d.feed(byteArrayOf(0, 0, 1, 2))
            fail("longitud 0")
        } catch (e: IOException) {
        }
        try {
            DotFraming.Deframer().feed(byteArrayOf(0, 5, 1, 2, 3, 4, 5)) // menos que una cabecera DNS
            fail("mensaje corto")
        } catch (e: IOException) {
        }
        try {
            DotFraming.Deframer(maxBuffered = 100).feed(ByteArray(200))
            fail("desbordado")
        } catch (e: IOException) {
        }
    }

    // --- Transporte (con sockets de texto plano en vez de TLS) -----------------------------

    /** Un servidor que contesta cada mensaje con él mismo con el bit de respuesta, y cuenta conexiones. */
    private class EchoServer(private val dropFirstConnection: Boolean = false) : AutoCloseable {
        val server = ServerSocket(0, 5, InetAddress.getLoopbackAddress())
        val address = InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort)
        val connections = AtomicInteger()

        init {
            Thread {
                while (!server.isClosed) {
                    val s = try { server.accept() } catch (e: Exception) { break }
                    val n = connections.incrementAndGet()
                    Thread {
                        runCatching {
                            val input = DataInputStream(s.getInputStream())
                            if (dropFirstConnection && n == 1) {
                                input.readUnsignedShort()
                                s.close()
                                return@runCatching
                            }
                            while (true) {
                                val len = input.readUnsignedShort()
                                val msg = ByteArray(len).also { input.readFully(it) }
                                msg[2] = (msg[2].toInt() or 0x80).toByte()
                                val frame = DotFraming.frame(msg)
                                // byte a byte: el lector tiene que reensamblar
                                for (b in frame) { s.getOutputStream().write(b.toInt()); s.getOutputStream().flush() }
                            }
                        }
                    }.apply { isDaemon = true; start() }
                }
            }.apply { isDaemon = true; start() }
        }

        override fun close() = server.close()
    }

    private fun plain(): (TlsDotTransport.Target) -> Socket = { t -> Socket().also { it.connect(t.address, 1_000) } }

    private fun waitFor(timeoutMs: Long = 3_000, cond: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!cond() && System.nanoTime() < end) Thread.sleep(10)
        assertTrue(cond())
    }

    @Test
    fun pipelinedQueriesAreAnsweredOverOnePersistentConnection() {
        val e = EchoServer().also { closeables += it }
        val got = CopyOnWriteArrayList<Int>()
        val t = TlsDotTransport(listOf(TlsDotTransport.Target(e.address, "x")), plain(), { m, from ->
            assertEquals(e.address, from)
            assertTrue((m[2].toInt() and 0x80) != 0)
            got += ((m[0].toInt() and 0xFF) shl 8) or (m[1].toInt() and 0xFF)
        }).also { closeables += it }
        for (i in 1..20) assertTrue(t.send(q("n$i.example", i)))
        waitFor { got.size == 20 }
        assertEquals((1..20).toList(), got.sorted())
        assertEquals("una sola conexión", 1, e.connections.get())
    }

    @Test
    fun itReconnectsAfterTheServerDropsTheConnection() {
        val e = EchoServer(dropFirstConnection = true).also { closeables += it }
        val got = AtomicInteger()
        val t = TlsDotTransport(listOf(TlsDotTransport.Target(e.address, "x")), plain(), { _, _ -> got.incrementAndGet() }).also { closeables += it }
        t.send(q("one.example", 1)) // el servidor la cierra sin contestar
        Thread.sleep(200)
        t.send(q("two.example", 2)) // la escritura falla o va a la conexión cerrada
        Thread.sleep(200)
        t.send(q("three.example", 3))
        waitFor { got.get() >= 1 }
        assertTrue(e.connections.get() >= 2)
    }

    @Test
    fun itTriesTheNextServerWhenTheFirstCannotConnect() {
        val e = EchoServer().also { closeables += it }
        val dead = InetSocketAddress(InetAddress.getLoopbackAddress(), 1)
        val tried = CopyOnWriteArrayList<InetSocketAddress>()
        val got = AtomicInteger()
        val t = TlsDotTransport(
            listOf(TlsDotTransport.Target(dead, "dead"), TlsDotTransport.Target(e.address, "ok")),
            { target -> tried += target.address; if (target.address == dead) throw IOException("sin ruta") else plain()(target) },
            { _, _ -> got.incrementAndGet() },
        ).also { closeables += it }
        t.send(q("a.example", 1))
        waitFor { got.get() == 1 }
        assertEquals(listOf(dead, e.address), tried.toList())
        t.send(q("b.example", 2)) // la siguiente ya no empieza por la muerta
        waitFor { got.get() == 2 }
        assertEquals(2, tried.size)
    }

    @Test
    fun whenNothingConnectsItDoesNotHammerTheNetwork() {
        val attempts = AtomicInteger()
        val t = TlsDotTransport(
            listOf(TlsDotTransport.Target(InetSocketAddress(InetAddress.getLoopbackAddress(), 1), "x")),
            { attempts.incrementAndGet(); throw IOException("no") }, { _, _ -> }, retryMs = 60_000,
        ).also { closeables += it }
        repeat(5) { t.send(q("a$it.example", it + 1)); Thread.sleep(30) }
        assertEquals(1, attempts.get())
    }

    @Test
    fun sendIsRefusedWhenClosedOrForJunkAndNeverBlocks() {
        val e = EchoServer().also { closeables += it }
        val t = TlsDotTransport(listOf(TlsDotTransport.Target(e.address, "x")), plain(), { _, _ -> })
        assertFalse(t.send(ByteArray(5)))
        t.close()
        assertFalse(t.send(q("a.example", 1)))
    }

    @Test
    fun theQueueIsBoundedWhenTheConnectionIsStuck() {
        val gate = java.util.concurrent.CountDownLatch(1)
        val t = TlsDotTransport(
            listOf(TlsDotTransport.Target(InetSocketAddress(InetAddress.getLoopbackAddress(), 1), "x")),
            { gate.await(); throw IOException("no") }, { _, _ -> },
        ).also { closeables += it; closeables += AutoCloseable { gate.countDown() } }
        val t0 = System.nanoTime()
        val accepted = (1..TlsDotTransport.QUEUE + 20).count { t.send(q("a$it.example", it)) }
        assertTrue("nunca bloquea: ${(System.nanoTime() - t0) / 1_000_000} ms", (System.nanoTime() - t0) < 1_000_000_000L)
        assertTrue("acotada: $accepted", accepted <= TlsDotTransport.QUEUE + 1)
    }

    // --- Recuperación -----------------------------------------------------------------------

    @Test
    fun aTunnelReadErrorIsRetriedOnlyWhileItIsNotPersistent() {
        assertTrue(TunnelRecovery.retryRead(destroyed = false, errors = 1, max = 5))
        assertTrue(TunnelRecovery.retryRead(destroyed = false, errors = 5, max = 5))
        assertFalse("persistente: se rehace la VPN", TunnelRecovery.retryRead(destroyed = false, errors = 6, max = 5))
        assertFalse("destruyéndose: no se reintenta", TunnelRecovery.retryRead(destroyed = true, errors = 1, max = 5))
    }

    @Test
    fun theReceiverRestartDelayGrowsAndIsCapped() {
        assertEquals(50L, DnsForwarder.receiverRestartDelayMs(1))
        assertEquals(100L, DnsForwarder.receiverRestartDelayMs(2))
        assertEquals(1_600L, DnsForwarder.receiverRestartDelayMs(6))
        assertEquals(2_000L, DnsForwarder.receiverRestartDelayMs(7))
        assertEquals(2_000L, DnsForwarder.receiverRestartDelayMs(1_000))
        assertEquals(50L, DnsForwarder.receiverRestartDelayMs(0))
    }
}
