package com.secretsavior

import com.secretsavior.PacketCheck.V4_8888
import com.secretsavior.PacketCheck.V4_CLIENT
import com.secretsavior.PacketCheck.V6_CLIENT
import com.secretsavior.PacketCheck.V6_GOOGLE
import com.secretsavior.PacketCheck.u16
import com.secretsavior.PacketCheck.u32
import com.secretsavior.vpn.IpPacket
import com.secretsavior.vpn.TcpDns
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TcpDnsTest {

    private val SYN = IpPacket.SYN
    private val ACK = IpPacket.ACK
    private val FIN = IpPacket.FIN
    private val RST = IpPacket.RST
    private val PSH = IpPacket.PSH

    /** Lo que el servidor mandó, ya verificado (checksums incluidos) y desmenuzado. */
    private class Seg(val flags: Int, val seq: Long, val ack: Long, val payload: ByteArray, val opts: ByteArray, val sport: Int, val dport: Int) {
        fun has(f: Int) = flags and f == f
    }

    private class Net(val v6: Boolean = false, val isn: Int = 1000, startAt: Long = 0) {
        val sent = ArrayList<ByteArray>()
        val queries = ArrayList<ByteArray>()
        val dones = ArrayList<(ByteArray?) -> Unit>()
        val scheduled = ArrayList<Pair<Long, Runnable>>()
        var now = startAt
        var throwOnResolve = false
        val client: ByteArray = if (v6) V6_CLIENT else V4_CLIENT
        val server: ByteArray = if (v6) V6_GOOGLE else V4_8888

        val dns = TcpDns(
            send = { sent += it },
            resolve = { q, d ->
                if (throwOnResolve) throw IllegalStateException("boom")
                queries += q; dones += d
            },
            clock = { now },
            newIsn = { isn },
            schedule = { delay, task -> scheduled += delay to task },
        )

        /** Un segmento del cliente (puerto [port]) entregado a [dns]. */
        fun client(
            port: Int, seq: Long, ack: Long, flags: Int, data: ByteArray? = null, opts: ByteArray? = null,
            from: ByteArray = client,
        ) {
            val pkt = IpPacket.tcp(v6, from, server, port, 53, seq, ack, flags, 5000, opts, data, 0, data?.size ?: 0)
            dns.onPacket(pkt, pkt.size, IpPacket.parse(pkt, pkt.size)!!)
        }

        /** Los segmentos enviados desde la última llamada. */
        fun take(): List<Seg> {
            val out = sent.map { parse(it) }
            sent.clear()
            return out
        }

        private fun parse(p: ByteArray): Seg {
            val i = PacketCheck.verify(p)
            assertEquals(6, i.proto)
            assertArrayEquals("origen = el servidor", server, i.src)
            assertArrayEquals("destino = el cliente", client, i.dst)
            val t = i.l4
            val off = ((p[t + 12].toInt() and 0xF0) shr 4) * 4
            return Seg(
                p[t + 13].toInt() and 0xFF, u32(p, t + 4), u32(p, t + 8),
                p.copyOfRange(t + off, p.size), p.copyOfRange(t + 20, t + off), u16(p, t), u16(p, t + 2),
            )
        }
    }

    private val CISN = 5000L
    private val PORT = 50000

    private fun dnsQuery(id: Int, tag: Int = 0): ByteArray =
        ByteArray(30) { (it + tag).toByte() }.also { it[0] = (id shr 8).toByte(); it[1] = id.toByte() }

    private fun framed(m: ByteArray) = byteArrayOf((m.size shr 8).toByte(), m.size.toByte()) + m

    /** SYN, SYN-ACK y ACK. Devuelve el número de secuencia del servidor (el siguiente). */
    private fun handshake(n: Net, port: Int = PORT, cisn: Long = CISN, opts: ByteArray? = null): Long {
        n.client(port, cisn, 0, SYN, opts = opts)
        val sa = n.take().single()
        assertTrue(sa.has(SYN) && sa.has(ACK))
        n.client(port, cisn + 1, sa.seq + 1, ACK)
        assertTrue("el ACK puro no se contesta", n.take().isEmpty())
        return sa.seq + 1
    }

    // --- Apretón de manos -----------------------------------------------------------------

    @Test
    fun synGetsASynAckWithTheRightNumbers() {
        for (v6 in listOf(false, true)) {
            val n = Net(v6, isn = 1000)
            n.client(PORT, CISN, 0, SYN, opts = byteArrayOf(2, 4, 5, 0xB4.toByte())) // MSS 1460
            val sa = n.take().single()
            assertEquals(SYN or ACK, sa.flags)
            assertEquals(1000L, sa.seq)
            assertEquals(CISN + 1, sa.ack)
            assertEquals(PORT, sa.dport); assertEquals(53, sa.sport)
            assertArrayEquals(byteArrayOf(2, 4, 0x05, 0x78), sa.opts) // anuncia MSS 1400
            assertEquals(1, n.dns.size)
        }
    }

    @Test
    fun retransmittedSynGetsTheSameSynAck() {
        val n = Net()
        n.client(PORT, CISN, 0, SYN)
        val a = n.take().single()
        n.client(PORT, CISN, 0, SYN)
        val b = n.take().single()
        assertEquals(a.seq, b.seq); assertEquals(a.ack, b.ack)
        assertEquals(1, n.dns.size)
    }

    @Test
    fun wrongAckInTheHandshakeIsResetAndForgotten() {
        val n = Net()
        n.client(PORT, CISN, 0, SYN)
        n.take()
        n.client(PORT, CISN + 1, 9999, ACK) // no confirma nuestro ISN
        val r = n.take().single()
        assertTrue(r.has(RST))
        assertEquals(9999L, r.seq)
        assertEquals(0, n.dns.size)
    }

    // --- Consultas ------------------------------------------------------------------------

    @Test
    fun singleQueryIsAckedResolvedAndAnswered() {
        for (v6 in listOf(false, true)) {
            val n = Net(v6)
            val sndNxt = handshake(n)
            val q = dnsQuery(0x1234)
            n.client(PORT, CISN + 1, sndNxt, ACK or PSH, framed(q))

            val ack = n.take().single()
            assertEquals(ACK, ack.flags)
            assertEquals(CISN + 1 + 2 + q.size, ack.ack)
            assertEquals(sndNxt, ack.seq)
            assertEquals(1, n.queries.size)
            assertArrayEquals("sin el prefijo de longitud", q, n.queries[0])

            val resp = ByteArray(80) { (it * 3).toByte() }
            n.dones[0](resp)
            val d = n.take().single()
            assertEquals(ACK or PSH, d.flags)
            assertEquals(sndNxt, d.seq)
            assertEquals(CISN + 1 + 2 + q.size, d.ack)
            assertArrayEquals(framed(resp), d.payload)
        }
    }

    @Test
    fun aQuerySplitOverSegmentsIsResolvedOnlyWhenComplete() {
        val n = Net()
        val sndNxt = handshake(n)
        val q = dnsQuery(7)
        val all = framed(q)
        // 1 byte (ni siquiera la longitud entera), luego un trozo, luego el resto
        val cuts = listOf(0 to 1, 1 to 10, 10 to all.size)
        for ((a, b) in cuts.dropLast(1)) {
            n.client(PORT, CISN + 1 + a, sndNxt, ACK, all.copyOfRange(a, b))
            val ack = n.take().single()
            assertEquals(CISN + 1 + b, ack.ack)
            assertTrue(n.queries.isEmpty())
        }
        n.client(PORT, CISN + 1 + 10, sndNxt, ACK, all.copyOfRange(10, all.size))
        assertEquals(CISN + 1 + all.size, n.take().single().ack)
        assertEquals(1, n.queries.size)
        assertArrayEquals(q, n.queries[0])
    }

    @Test
    fun twoPipelinedQueriesInOneSegmentAreBothAnswered() {
        val n = Net()
        val sndNxt = handshake(n)
        val q1 = dnsQuery(1, 0)
        val q2 = dnsQuery(2, 50)
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(q1) + framed(q2))
        assertEquals(CISN + 1 + framed(q1).size + framed(q2).size, n.take().single().ack)
        assertEquals(2, n.queries.size)
        assertArrayEquals(q1, n.queries[0]); assertArrayEquals(q2, n.queries[1])

        // contestan desordenadas: cada una sale entera y la secuencia propia no se pisa
        val r2 = ByteArray(10) { 2 }
        val r1 = ByteArray(20) { 1 }
        n.dones[1](r2)
        n.dones[0](r1)
        val out = n.take()
        assertEquals(2, out.size)
        assertEquals(sndNxt, out[0].seq)
        assertEquals(sndNxt + 2 + r2.size, out[1].seq)
        assertArrayEquals(framed(r2), out[0].payload)
        assertArrayEquals(framed(r1), out[1].payload)
    }

    @Test
    fun queriesInSeparateSegmentsAdvanceTheAckEachTime() {
        val n = Net()
        val sndNxt = handshake(n)
        val q1 = framed(dnsQuery(1)); val q2 = framed(dnsQuery(2))
        n.client(PORT, CISN + 1, sndNxt, ACK, q1)
        assertEquals(CISN + 1 + q1.size, n.take().single().ack)
        n.client(PORT, CISN + 1 + q1.size, sndNxt, ACK, q2)
        assertEquals(CISN + 1 + q1.size + q2.size, n.take().single().ack)
        assertEquals(2, n.queries.size)
    }

    @Test
    fun aBigAnswerIsSegmentedAtMost1400BytesAndContiguous() {
        val n = Net()
        val sndNxt = handshake(n, opts = byteArrayOf(2, 4, 5, 0xB4.toByte()))
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(9)))
        n.take()
        val resp = ByteArray(4000) { (it % 251).toByte() }
        n.dones[0](resp)
        val segs = n.take()
        assertEquals(3, segs.size) // 4002 bytes / 1400
        var expected = sndNxt
        val joined = java.io.ByteArrayOutputStream()
        for ((i, s) in segs.withIndex()) {
            assertTrue(s.payload.size <= 1400)
            assertEquals(expected, s.seq)
            assertEquals("PSH sólo en el último", i == segs.size - 1, s.has(PSH))
            expected += s.payload.size
            joined.write(s.payload)
        }
        assertArrayEquals(framed(resp), joined.toByteArray())
    }

    @Test
    fun theClientsSmallMssLimitsTheSegments() {
        val n = Net()
        val sndNxt = handshake(n, opts = byteArrayOf(2, 4, 2, 0x58)) // MSS 600
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(9)))
        n.take()
        n.dones[0](ByteArray(1500))
        val segs = n.take()
        assertTrue(segs.all { it.payload.size <= 600 })
        assertEquals(1502, segs.sumOf { it.payload.size })
    }

    @Test
    fun sequenceNumbersWrapAroundAt32Bits() {
        val n = Net(isn = -2) // 0xFFFFFFFE
        val cisn = 0xFFFFFFF0L
        n.client(PORT, cisn, 0, SYN)
        val sa = n.take().single()
        assertEquals(0xFFFFFFFEL, sa.seq)
        n.client(PORT, cisn + 1, sa.seq + 1, ACK)
        val q = framed(dnsQuery(3))
        n.client(PORT, cisn + 1, (sa.seq + 1) and 0xFFFFFFFFL, ACK, q) // el ACK del cliente: 0xFFFFFFFF
        assertEquals((cisn + 1 + q.size) and 0xFFFFFFFFL, n.take().single().ack) // dio la vuelta
        n.dones[0](ByteArray(20))
        val d = n.take().single()
        assertEquals(0xFFFFFFFFL, d.seq)
        // el siguiente propio es 0xFFFFFFFF + 22 = 21 (mod 2^32)
        n.client(PORT, (cisn + 1 + q.size) and 0xFFFFFFFFL, 21, ACK or FIN)
        assertEquals(21L, n.take().single().seq)
    }

    // --- Cierre ---------------------------------------------------------------------------

    @Test
    fun clientFinGetsFinAckAndTheConnectionIsForgotten() {
        for (v6 in listOf(false, true)) {
            val n = Net(v6)
            val sndNxt = handshake(n)
            n.client(PORT, CISN + 1, sndNxt, ACK or FIN)
            val f = n.take().single()
            assertEquals(FIN or ACK, f.flags)
            assertEquals(CISN + 2, f.ack)
            assertEquals(sndNxt, f.seq)
            assertEquals(0, n.dns.size)
            // el último ACK del cliente llega a una conexión que ya no existe: RST sin consecuencias
            n.client(PORT, CISN + 2, sndNxt + 1, ACK)
            assertTrue(n.take().single().has(RST))
        }
    }

    @Test
    fun finWithAQueryInFlightWaitsForTheAnswerThenCloses() {
        val n = Net()
        val sndNxt = handshake(n)
        val q = framed(dnsQuery(4))
        n.client(PORT, CISN + 1, sndNxt, ACK or FIN, q) // consulta y FIN juntas
        val ack = n.take().single()
        assertEquals(ACK, ack.flags)
        assertEquals(CISN + 1 + q.size + 1, ack.ack)
        assertEquals(1, n.dns.size)
        n.dones[0](ByteArray(15))
        val out = n.take()
        assertEquals(2, out.size)
        assertEquals(ACK or PSH, out[0].flags)
        assertEquals(FIN or ACK, out[1].flags)
        assertEquals(sndNxt + 17, out[1].seq)
        assertEquals(0, n.dns.size)
    }

    @Test
    fun resetForgetsTheConnection() {
        val n = Net()
        val sndNxt = handshake(n)
        n.client(PORT, CISN + 1, sndNxt, RST)
        assertTrue(n.take().isEmpty())
        assertEquals(0, n.dns.size)
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(1)))
        assertTrue(n.take().single().has(RST))
        assertTrue(n.queries.isEmpty())
    }

    @Test
    fun unknownConnectionsGetAReset() {
        for (v6 in listOf(false, true)) {
            val n = Net(v6)
            n.client(PORT, 100, 7777, ACK, framed(dnsQuery(1)))
            val r = n.take().single()
            assertEquals(RST, r.flags)
            assertEquals(7777L, r.seq) // RFC 793: seq = el ack del segmento
            n.client(PORT + 1, 100, 0, FIN or ACK)
            assertTrue(n.take().single().has(RST))
            n.client(PORT + 2, 100, 0, RST) // a un RST no se contesta
            assertTrue(n.take().isEmpty())
            assertTrue(n.queries.isEmpty())
            assertEquals(0, n.dns.size)
        }
    }

    // --- Repeticiones y huecos ------------------------------------------------------------

    @Test
    fun retransmittedDataIsReackedAndNotResolvedTwice() {
        val n = Net()
        val sndNxt = handshake(n)
        val q = framed(dnsQuery(5))
        n.client(PORT, CISN + 1, sndNxt, ACK, q)
        val first = n.take().single()
        n.client(PORT, CISN + 1, sndNxt, ACK, q) // mismo segmento otra vez
        val again = n.take().single()
        assertEquals(first.ack, again.ack)
        assertEquals(ACK, again.flags)
        assertEquals(1, n.queries.size)
    }

    @Test
    fun overlappingRetransmissionOnlyAddsTheNewBytes() {
        val n = Net()
        val sndNxt = handshake(n)
        val q = dnsQuery(6)
        val all = framed(q)
        n.client(PORT, CISN + 1, sndNxt, ACK, all.copyOfRange(0, 5))
        n.take()
        n.client(PORT, CISN + 1 + 3, sndNxt, ACK, all.copyOfRange(3, all.size)) // repite 2 bytes
        assertEquals(CISN + 1 + all.size, n.take().single().ack)
        assertEquals(1, n.queries.size)
        assertArrayEquals(q, n.queries[0])
    }

    @Test
    fun aGapIsDuplicateAckedAndDiscarded() {
        val n = Net()
        val sndNxt = handshake(n)
        val all = framed(dnsQuery(8))
        n.client(PORT, CISN + 1 + 10, sndNxt, ACK, all.copyOfRange(10, all.size)) // falta el principio
        val dup = n.take().single()
        assertEquals(CISN + 1, dup.ack)
        assertTrue(n.queries.isEmpty())
        // al llegar lo que faltaba (y el resto otra vez) todo encaja
        n.client(PORT, CISN + 1, sndNxt, ACK, all)
        assertEquals(CISN + 1 + all.size, n.take().single().ack)
        assertEquals(1, n.queries.size)
    }

    @Test
    fun retransmittedFinIsReacked() {
        val n = Net()
        val sndNxt = handshake(n)
        val q = framed(dnsQuery(4))
        n.client(PORT, CISN + 1, sndNxt, ACK or FIN, q)
        n.take()
        n.client(PORT, CISN + 1, sndNxt, ACK or FIN, q) // con la respuesta aún pendiente
        val a = n.take().single()
        assertEquals(ACK, a.flags)
        assertEquals(CISN + 1 + q.size + 1, a.ack)
        assertEquals(1, n.queries.size)
    }

    // --- Errores --------------------------------------------------------------------------

    @Test
    fun aFailedResolutionResetsTheConnection() {
        val n = Net()
        val sndNxt = handshake(n)
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(1)))
        n.take()
        n.dones[0](null)
        assertTrue(n.take().single().has(RST))
        assertEquals(0, n.dns.size)
        n.dones[0](ByteArray(20)) // una respuesta tardía a una conexión muerta no hace nada
        assertTrue(n.take().isEmpty())
    }

    @Test
    fun aResolverThatThrowsNeverReachesTheCaller() {
        val n = Net()
        val sndNxt = handshake(n)
        n.throwOnResolve = true
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(1)))
        val out = n.take()
        assertTrue(out.last().has(RST))
        assertEquals(0, n.dns.size)
    }

    @Test
    fun nonsenseLengthPrefixResetsInsteadOfWaiting() {
        val n = Net()
        val sndNxt = handshake(n)
        n.client(PORT, CISN + 1, sndNxt, ACK, byteArrayOf(0, 3, 1, 2, 3)) // un "mensaje" de 3 bytes
        assertTrue(n.take().single().has(RST))
        assertEquals(0, n.dns.size)
    }

    @Test
    fun garbageNeverThrows() {
        val n = Net()
        // cabecera TCP truncada o con offset de datos imposible
        val ok = IpPacket.tcp(false, V4_CLIENT, V4_8888, PORT, 53, 1, 0, SYN, 100, null, null, 0, 0)
        val short = ok.copyOf(30)
        n.dns.onPacket(short, short.size, IpPacket.parse(short, short.size)!!)
        val badOff = ok.copyOf().also { it[20 + 12] = 0xF0.toByte() } // 60 bytes de cabecera en un segmento de 20
        n.dns.onPacket(badOff, badOff.size, IpPacket.parse(badOff, badOff.size)!!)
        assertTrue(n.sent.isEmpty())
        assertEquals(0, n.dns.size)
    }

    // --- Límites --------------------------------------------------------------------------

    @Test
    fun atMost256ConnectionsOldestEvictedWithAReset() {
        val n = Net()
        for (i in 0 until TcpDns.MAX_CONNS) {
            n.now = i.toLong()
            n.client(20000 + i, CISN, 0, SYN)
        }
        assertEquals(256, n.dns.size)
        n.sent.clear()
        n.now = 1000
        n.client(30000, CISN, 0, SYN)
        val out = n.take()
        assertEquals(2, out.size)
        assertEquals(RST or ACK, out[0].flags) // la expulsada (la más antigua, puerto 20000)
        assertEquals(20000, out[0].dport)
        assertEquals(SYN or ACK, out[1].flags)
        assertEquals(256, n.dns.size)
        // la expulsada ya no existe
        n.client(20000, CISN + 1, 1001, ACK, framed(dnsQuery(1)))
        assertTrue(n.take().single().has(RST))
    }

    @Test
    fun idleConnectionsGetAFinAfterTenSeconds() {
        val n = Net()
        n.client(PORT, CISN, 0, SYN)
        val sa = n.take().single()
        n.client(PORT, CISN + 1, sa.seq + 1, ACK)
        n.now = 9_000
        n.client(PORT + 1, CISN, 0, SYN) // otra, más reciente
        n.take()
        n.now = 10_500
        n.dns.sweep()
        val f = n.take().single()
        assertEquals(FIN or ACK, f.flags)
        assertEquals(PORT, f.dport)
        assertEquals(1, n.dns.size) // la reciente sigue
        n.now = 20_000
        n.dns.sweep()
        assertEquals(PORT + 1, n.take().single().dport)
        assertEquals(0, n.dns.size)
    }

    @Test
    fun activityKeepsAConnectionAlive() {
        val n = Net()
        val sndNxt = handshake(n)
        n.now = 8_000
        n.client(PORT, CISN + 1, sndNxt, ACK, framed(dnsQuery(1)))
        n.take()
        n.now = 15_000 // 7 s desde la última actividad
        n.dns.sweep()
        assertTrue(n.take().isEmpty())
        assertEquals(1, n.dns.size)
    }

    @Test
    fun theSweepIsScheduledOnlyWhileThereAreConnections() {
        val n = Net()
        assertTrue(n.scheduled.isEmpty()) // sin conexiones, ningún temporizador
        n.client(PORT, CISN, 0, SYN)
        n.client(PORT + 1, CISN, 0, SYN)
        assertEquals(1, n.scheduled.size) // uno solo, no uno por conexión
        n.now = 30_000
        n.scheduled.removeAt(0).second.run() // el barrido cierra todo y no se vuelve a pedir
        assertEquals(0, n.dns.size)
        assertTrue(n.scheduled.isEmpty())
        n.take()
        n.client(PORT, CISN, 0, SYN) // una conexión nueva reactiva el barrido
        assertEquals(1, n.scheduled.size)
    }

    @Test
    fun theSweepKeepsRunningWhileAConnectionLives() {
        val n = Net()
        n.client(PORT, CISN, 0, SYN)
        n.now = 2_000
        n.scheduled.removeAt(0).second.run()
        assertEquals(1, n.dns.size)
        assertEquals(1, n.scheduled.size)
        assertFalse(n.scheduled[0].first <= 0)
    }

    @Test
    fun connectionsOfDifferentClientsOrPortsAreIndependent() {
        val n = Net()
        val a = handshake(n, port = 40001, cisn = 100)
        val b = handshake(n, port = 40002, cisn = 900)
        n.client(40001, 101, a, ACK, framed(dnsQuery(1)))
        val ackA = n.take().single()
        assertEquals(40001, ackA.dport)
        assertEquals(101L + 32, ackA.ack)
        n.client(40002, 901, b, ACK, framed(dnsQuery(2)))
        assertEquals(901L + 32, n.take().single().ack)
        assertEquals(2, n.queries.size)
        assertEquals(2, n.dns.size)
    }
}
