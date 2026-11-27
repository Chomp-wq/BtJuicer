package com.secretsavior

import com.secretsavior.vpn.DnsCache
import com.secretsavior.vpn.DnsForwarder
import com.secretsavior.vpn.DnsPacket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ForwarderTest {

    private val lo: InetAddress = InetAddress.getLoopbackAddress()

    /** Un resolutor de mentira: contesta repitiendo la consulta con el bit de respuesta puesto. */
    private class FakeDns(val delayMs: Long = 0, val silent: Boolean = false, val truncate: Boolean = false) : AutoCloseable {
        val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
        val address = InetSocketAddress(InetAddress.getLoopbackAddress(), socket.localPort)
        val received = AtomicInteger()

        @Volatile
        var lastQuery: ByteArray? = null
        private val delayer = Executors.newSingleThreadScheduledExecutor()

        init {
            Thread {
                val buf = ByteArray(4096)
                while (!socket.isClosed) {
                    val p = DatagramPacket(buf, buf.size)
                    try {
                        socket.receive(p)
                    } catch (e: Exception) {
                        break
                    }
                    received.incrementAndGet()
                    lastQuery = buf.copyOf(p.length)
                    if (silent) continue
                    val reply = buf.copyOf(p.length).also {
                        it[2] = (it[2].toInt() or 0x80 or (if (truncate) 0x02 else 0)).toByte()
                    }
                    val to = p.socketAddress
                    delayer.schedule({ runCatching { socket.send(DatagramPacket(reply, reply.size, to)) } }, delayMs, TimeUnit.MILLISECONDS)
                }
            }.apply { isDaemon = true; start() }
        }

        override fun close() {
            socket.close()
            delayer.shutdownNow()
        }
    }

    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() = closeables.forEach { runCatching { it.close() } }

    private fun fake(delayMs: Long = 0, silent: Boolean = false, truncate: Boolean = false) =
        FakeDns(delayMs, silent, truncate).also { closeables += it }

    private fun forwarder(primaries: List<FakeDns>, fallbacks: List<FakeDns>, escalateMs: Long = 150, giveUpMs: Long = 600) =
        DnsForwarder(primaries.map { it.address }, fallbacks.map { it.address }, protect = {}, cache = null, escalateAfterMs = escalateMs, giveUpAfterMs = giveUpMs)
            .also { closeables += it }

    // Plazo = red de seguridad (CI lenta); se espera por eventos, no por pausas fijas.
    private fun waitUntil(timeoutMs: Long = 20_000, what: String = "condición", cond: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!cond() && System.nanoTime() < end) Thread.sleep(10)
        assertTrue("$what no se cumplió a tiempo", cond())
    }

    /** Una consulta A de verdad: cabecera, nombre, tipo e IN. */
    private fun q(name: String, id: Int, type: Int = 1, edns: Int? = null): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf((id shr 8).toByte(), id.toByte(), 1, 0, 0, 1, 0, 0, 0, 0, 0, if (edns != null) 1 else 0))
        for (l in name.split('.').filter { it.isNotEmpty() }) { b.write(l.length); b.write(l.toByteArray()) }
        b.write(0); b.write(0); b.write(type); b.write(0); b.write(1)
        if (edns != null) b.write(byteArrayOf(0, 0, 41, (edns shr 8).toByte(), edns.toByte(), 0, 0, 0, 0, 0, 0))
        return b.toByteArray()
    }

    private fun ask(f: DnsForwarder, id: Int, name: String = "example.com", timeoutMs: Long = 20_000): ByteArray? {
        val latch = CountDownLatch(1)
        var result: ByteArray? = null
        f.query(q(name, id)) { result = it; latch.countDown() }
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
        f.query(q("example.com", 7)) { calls.incrementAndGet(); latch.countDown() }
        assertTrue(latch.await(20, TimeUnit.SECONDS))
        waitUntil(what = "los dos primarios reciben") { a.received.get() == 1 && b.received.get() == 1 }
        Thread.sleep(200) // la segunda respuesta llega y se descarta
        assertEquals(1, calls.get())
        assertEquals(1, a.received.get())
        assertEquals(1, b.received.get())
    }

    @Test
    fun fallsBackWhenPrimariesAreSilent() {
        val fallback = fake()
        val f = forwarder(listOf(fake(silent = true), fake(silent = true)), listOf(fallback), giveUpMs = 10_000)
        val start = System.nanoTime()
        assertNotNull(ask(f, 1))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertTrue("tardó $ms ms", ms >= 100) // no antes de la espera; contestó el de reserva, no el abandono (10 s)
        assertEquals(1, fallback.received.get())
    }

    @Test
    fun aNetworkChangeResendsInFlightQueriesAtOnce() {
        // Ignora el primer paquete (el de la red vieja) y contesta el segundo.
        val server = DatagramSocket(0, lo).also { closeables += AutoCloseable { it.close() } }
        val count = AtomicInteger()
        Thread {
            val buf = ByteArray(4096)
            while (!server.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                try { server.receive(p) } catch (e: Exception) { break }
                if (count.incrementAndGet() < 2) continue
                val reply = buf.copyOf(p.length).also { it[2] = (it[2].toInt() or 0x80).toByte() }
                server.send(DatagramPacket(reply, reply.size, p.socketAddress))
            }
        }.apply { isDaemon = true; start() }
        val f = DnsForwarder(
            listOf(InetSocketAddress(lo, server.localPort)), emptyList(),
            protect = {}, cache = null, escalateAfterMs = 30_000, giveUpAfterMs = 60_000,
        ).also { closeables += it }

        val latch = CountDownLatch(1)
        var result: ByteArray? = null
        val start = System.nanoTime()
        f.query(q("example.com", 5)) { result = it; latch.countDown() }
        waitUntil(what = "el primer paquete") { count.get() == 1 } // salió y se ignoró
        f.onNetworkChanged()
        // la escalada (30 s) queda muy lejos: sólo el reenvío del cambio de red pudo contestar
        assertTrue("sin respuesta tras el cambio de red", latch.await(20, TimeUnit.SECONDS))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertNotNull(result)
        assertTrue("tardó $ms ms", ms < 25_000)
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
        // Con 500 ms por consulta, un hilo por consulta (seis hilos) tardaría 300 * 0,5 / 6 = 25 s;
        // en paralelo real, algo más de 0,5 s. El umbral queda en medio con mucho margen.
        val f = forwarder(listOf(fake(delayMs = 500)), listOf(fake()), escalateMs = 30_000, giveUpMs = 60_000)
        val latch = CountDownLatch(300)
        val ok = AtomicInteger()
        val start = System.nanoTime()
        repeat(300) { i -> f.query(q("example.com", i)) { if (it != null) ok.incrementAndGet(); latch.countDown() } }
        assertTrue(latch.await(40, TimeUnit.SECONDS))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertEquals(300, ok.get())
        assertTrue("tardó $ms ms", ms < 12_000)
    }

    @Test
    fun anUnreachableIpv6ServerDoesNotGetInTheWay() {
        // Donde no hay IPv6 el envío falla al instante; la IPv4 contesta igual de rápido.
        val v4 = fake()
        val f = DnsForwarder(
            listOf(InetSocketAddress("2001:db8::1", 53), v4.address), emptyList(), protect = {}, cache = null,
            escalateAfterMs = 10_000, giveUpAfterMs = 20_000,
        ).also { closeables += it }
        val start = System.nanoTime()
        assertNotNull(ask(f, 3))
        // contestó la IPv4 al momento, sin esperar a la escalada (10 s)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 5_000)
    }

    @Test
    fun largeAnswersArriveWhole() {
        // Un resolutor que contesta 9000 bytes: antes el búfer de 4096 la cortaba.
        val big = DatagramSocket(0, lo).also { s -> closeables += AutoCloseable { s.close() } }
        Thread {
            val buf = ByteArray(512)
            val p = DatagramPacket(buf, buf.size)
            runCatching {
                big.receive(p)
                val reply = ByteArray(9000).also { buf.copyInto(it, 0, 0, p.length); it[2] = (it[2].toInt() or 0x80).toByte() }
                big.send(DatagramPacket(reply, reply.size, p.socketAddress))
            }
        }.apply { isDaemon = true; start() }
        val f = DnsForwarder(listOf(InetSocketAddress(lo, big.localPort)), emptyList(), protect = {}, cache = null)
            .also { closeables += it }
        assertEquals(9000, ask(f, 4)!!.size)
    }

    @Test
    fun keepsAnAverageLatency() {
        val f = forwarder(listOf(fake(delayMs = 60)), listOf(fake()))
        repeat(5) { assertNotNull(ask(f, 100 + it)) }
        assertEquals(5, f.answered)
        assertTrue("media ${f.averageMs} ms", f.averageMs in 50..3_000)
    }

    @Test
    fun countsRecentFailures() {
        val f = forwarder(listOf(fake(silent = true)), listOf(fake(silent = true)))
        assertNull(ask(f, 5))
        assertEquals(1, f.recentTotal)
        assertEquals(1, f.recentFailed)
    }

    // --- Lo que el identificador de 16 bits no basta para distinguir ---------------------

    @Test
    fun anAnswerToAnotherQuestionWithTheSameIdIsNotAccepted() {
        // Una respuesta repetida y tardía de otra consulta puede traer el id de ésta. Antes se
        // entregaba como suya (el cliente la descarta y espera 5 s) y la buena llegaba a nadie.
        val server = DatagramSocket(0, lo).also { s -> closeables += AutoCloseable { s.close() } }
        Thread {
            val buf = ByteArray(512)
            val p = DatagramPacket(buf, buf.size)
            runCatching {
                server.receive(p)
                val asked = buf.copyOf(p.length)
                val wrong = q("evil.example", 0).also { it[0] = asked[0]; it[1] = asked[1]; it[2] = (it[2].toInt() or 0x80).toByte() }
                server.send(DatagramPacket(wrong, wrong.size, p.socketAddress))
                Thread.sleep(120)
                val right = asked.copyOf().also { it[2] = (it[2].toInt() or 0x80).toByte() }
                server.send(DatagramPacket(right, right.size, p.socketAddress))
            }
        }.apply { isDaemon = true; start() }
        val f = DnsForwarder(listOf(InetSocketAddress(lo, server.localPort)), emptyList(), protect = {}, cache = null, escalateAfterMs = 1_000, giveUpAfterMs = 3_000)
            .also { closeables += it }
        val r = ask(f, 6, "example.com")!!
        assertEquals("example.com/1/1", DnsPacket.questionKey(r))
    }

    @Test
    fun theNameIsComparedIgnoringCase() {
        // Algunos servidores devuelven el nombre con otras mayúsculas: sigue siendo la misma pregunta.
        val server = DatagramSocket(0, lo).also { s -> closeables += AutoCloseable { s.close() } }
        Thread {
            val buf = ByteArray(512)
            val p = DatagramPacket(buf, buf.size)
            runCatching {
                server.receive(p)
                val r = buf.copyOf(p.length)
                r[2] = (r[2].toInt() or 0x80).toByte()
                for (i in 13 until r.size - 5) if (r[i] in 'a'.code.toByte()..'z'.code.toByte()) r[i] = (r[i] - 32).toByte()
                server.send(DatagramPacket(r, r.size, p.socketAddress))
            }
        }.apply { isDaemon = true; start() }
        val f = DnsForwarder(listOf(InetSocketAddress(lo, server.localPort)), emptyList(), protect = {}, cache = null)
            .also { closeables += it }
        assertNotNull(ask(f, 8, "example.com"))
    }

    @Test
    fun anAnswerFromAServerThatWasNotAskedIsIgnored() {
        val silent = fake(silent = true)
        val f = DnsForwarder(listOf(silent.address), emptyList(), protect = {}, cache = null, escalateAfterMs = 2_000, giveUpAfterMs = 4_000)
            .also { closeables += it }
        val latch = CountDownLatch(1)
        var result: ByteArray? = byteArrayOf()
        f.query(q("example.com", 9)) { result = it; latch.countDown() }
        // Un tercero que conoce el id (lo vio pasar) intenta colar una respuesta desde otro puerto.
        waitUntil(what = "la consulta en el servidor") { silent.lastQuery != null }
        val asked = silent.lastQuery!!
        val forged = asked.copyOf().also { it[2] = (it[2].toInt() or 0x80).toByte() }
        DatagramSocket().use { it.send(DatagramPacket(forged, forged.size, lo, f.currentSocket().localPort)) }
        assertTrue(latch.await(20, TimeUnit.SECONDS))
        assertNull("sólo cuenta lo que llega de un servidor al que se preguntó", result)
    }

    @Test
    fun aQueryThatBouncesBackIsNotAnAnswer() {
        val silent = fake(silent = true)
        val f = DnsForwarder(listOf(silent.address), emptyList(), protect = {}, cache = null, escalateAfterMs = 2_000, giveUpAfterMs = 4_000)
            .also { closeables += it }
        val latch = CountDownLatch(1)
        var result: ByteArray? = byteArrayOf()
        f.query(q("example.com", 10)) { result = it; latch.countDown() }
        waitUntil(what = "la consulta en el servidor") { silent.lastQuery != null }
        val echoed = silent.lastQuery!! // sin el bit de respuesta
        DatagramSocket(0, lo).use { it.send(DatagramPacket(echoed, echoed.size, lo, f.currentSocket().localPort)) }
        assertTrue(latch.await(20, TimeUnit.SECONDS))
        assertNull(result)
    }

    // --- Respuestas cortadas (TC) -------------------------------------------------------

    private fun udpAndTcpOnTheSamePort(extraBytes: Int): FakeDns {
        repeat(20) {
            val udp = fake(truncate = true)
            try {
                val tcp = ServerSocket(udp.address.port, 5, lo).also { closeables += AutoCloseable { it.close() } }
                Thread {
                    while (!tcp.isClosed) {
                        val s = try { tcp.accept() } catch (e: Exception) { break }
                        runCatching {
                            val input = DataInputStream(s.getInputStream())
                            val n = input.readUnsignedShort()
                            val query = ByteArray(n).also { input.readFully(it) }
                            val r = query.copyOf(n + extraBytes)
                            r[2] = (r[2].toInt() or 0x80).toByte() // respuesta, sin TC
                            r[7] = 1 // una respuesta
                            s.getOutputStream().apply {
                                write(byteArrayOf((r.size shr 8).toByte(), r.size.toByte()))
                                write(r)
                                flush()
                            }
                        }
                        runCatching { s.close() }
                    }
                }.apply { isDaemon = true; start() }
                return udp
            } catch (e: java.net.BindException) {
                udp.close()
            }
        }
        error("sin un puerto libre para UDP y TCP a la vez")
    }

    @Test
    fun aTruncatedAnswerIsRetriedOverTcp() {
        val server = udpAndTcpOnTheSamePort(extraBytes = 4)
        val f = DnsForwarder(listOf(server.address), emptyList(), protect = {}, cache = null, escalateAfterMs = 1_000, giveUpAfterMs = 3_000)
            .also { closeables += it }
        val query = q("example.com", 0x2222)
        val r = ask(f, 0x2222)!!
        assertEquals("llegó la respuesta completa, la de TCP", query.size + 4, r.size)
        assertEquals("sin TC", 0, r[2].toInt() and 0x02)
        assertEquals(0x22, r[0].toInt())
        assertEquals(0x22, r[1].toInt())
    }

    @Test
    fun aTruncatedAnswerIsDeliveredAsIsWhenTcpFails() {
        val udp = fake(truncate = true) // y nadie escucha por TCP
        val f = DnsForwarder(listOf(udp.address), emptyList(), protect = {}, cache = null, escalateAfterMs = 1_000, giveUpAfterMs = 3_000)
            .also { closeables += it }
        val r = ask(f, 11, timeoutMs = 4_000)!!
        assertTrue("sigue cortada", DnsPacket.isTruncated(r))
    }

    // --- Un socket roto no debe dejar al teléfono sin DNS ni gastar CPU -------------------

    @Test
    fun aBrokenSocketIsReplacedAndDnsKeepsWorking() {
        val s = fake()
        val f = DnsForwarder(listOf(s.address), emptyList(), protect = {}, cache = null, escalateAfterMs = 150, giveUpAfterMs = 400)
            .also { closeables += it }
        assertNotNull(ask(f, 12))
        f.currentSocket().close() // el sistema lo cierra, p. ej. al cambiar de red
        var answered = false
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (!answered && System.nanoTime() < deadline) {
            answered = ask(f, 13, timeoutMs = 10_000) != null
        }
        assertTrue("el DNS no se recuperó tras romperse el socket", answered)
    }

    @Test
    fun aClosedForwarderAnswersNullInsteadOfThrowing() {
        val s = fake()
        val f = DnsForwarder(listOf(s.address), emptyList(), protect = {}, cache = null)
        f.close()
        assertNull(ask(f, 14))
    }

    // --- Caché -----------------------------------------------------------------------------

    /** Un resolutor que da una dirección A de verdad, con TTL, para que la caché tenga qué guardar. */
    private class AnswerDns(val ttl: Int, val delayMs: Long = 0) : AutoCloseable {
        val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
        val address = InetSocketAddress(InetAddress.getLoopbackAddress(), socket.localPort)
        val received = AtomicInteger()

        @Volatile
        var ip = byteArrayOf(1, 1, 1, 1)
        private val delayer = Executors.newSingleThreadScheduledExecutor()

        init {
            Thread {
                val buf = ByteArray(4096)
                while (!socket.isClosed) {
                    val p = DatagramPacket(buf, buf.size)
                    try {
                        socket.receive(p)
                    } catch (e: Exception) {
                        break
                    }
                    received.incrementAndGet()
                    val query = buf.copyOf(p.length)
                    val end = DnsPacket.parseQuestion(query)!!.end
                    val out = ByteArrayOutputStream()
                    out.write(query, 0, 2)
                    out.write(byteArrayOf(0x81.toByte(), 0x80.toByte(), 0, 1, 0, 1, 0, 0, 0, 0))
                    out.write(query, 12, end - 12)
                    out.write(byteArrayOf(0xC0.toByte(), 0x0C, 0, 1, 0, 1))
                    out.write(byteArrayOf((ttl shr 24).toByte(), (ttl shr 16).toByte(), (ttl shr 8).toByte(), ttl.toByte(), 0, 4))
                    out.write(ip)
                    val reply = out.toByteArray()
                    val to = p.socketAddress
                    delayer.schedule({ runCatching { socket.send(DatagramPacket(reply, reply.size, to)) } }, delayMs, TimeUnit.MILLISECONDS)
                }
            }.apply { isDaemon = true; start() }
        }

        override fun close() {
            socket.close()
            delayer.shutdownNow()
        }
    }

    private fun answerDns(ttl: Int, delayMs: Long = 0) = AnswerDns(ttl, delayMs).also { closeables += it }

    private fun cachedForwarder(server: AnswerDns, cache: DnsCache) =
        DnsForwarder(listOf(server.address), emptyList(), protect = {}, escalateAfterMs = 1_000, giveUpAfterMs = 3_000, cache = cache)
            .also { closeables += it }

    private fun ipOf(r: ByteArray) = r.copyOfRange(r.size - 4, r.size).joinToString(".") { (it.toInt() and 0xFF).toString() }

    @Test
    fun aRepeatedQueryIsAnsweredFromTheCacheWithoutTheNetwork() {
        val server = answerDns(ttl = 300)
        val f = cachedForwarder(server, DnsCache())
        val first = ask(f, 0x0101)!!
        assertEquals("1.1.1.1", ipOf(first))
        val second = ask(f, 0x0202, name = "EXAMPLE.com")!!
        assertEquals("1.1.1.1", ipOf(second))
        assertEquals(0x02, second[0].toInt())
        assertEquals(0x02, second[1].toInt())
        assertEquals(1, server.received.get())
        assertEquals(1, f.cacheHits)
        assertEquals(2, f.cacheLookups)
    }

    // El comportamiento con caducadas (primero lo fresco) está en FreshFirstTest.
}
