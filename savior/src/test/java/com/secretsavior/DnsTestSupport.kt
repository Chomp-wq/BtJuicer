package com.secretsavior

import com.secretsavior.vpn.DnsPacket
import com.secretsavior.vpn.DotTransport
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Una consulta A (o del tipo dado) de verdad: cabecera, nombre, tipo e IN. */
fun dnsQuery(name: String, id: Int, type: Int = 1, edns: Int? = null): ByteArray {
    val b = ByteArrayOutputStream()
    b.write(byteArrayOf((id shr 8).toByte(), id.toByte(), 1, 0, 0, 1, 0, 0, 0, 0, 0, if (edns != null) 1 else 0))
    for (l in name.split('.').filter { it.isNotEmpty() }) { b.write(l.length); b.write(l.toByteArray()) }
    b.write(0); b.write(0); b.write(type); b.write(0); b.write(1)
    if (edns != null) b.write(byteArrayOf(0, 0, 41, (edns shr 8).toByte(), edns.toByte(), 0, 0, 0, 0, 0, 0))
    return b.toByteArray()
}

/** Los cuatro últimos bytes de una respuesta A como "a.b.c.d". */
fun ipOfAnswer(r: ByteArray) = r.copyOfRange(r.size - 4, r.size).joinToString(".") { (it.toInt() and 0xFF).toString() }

/**
 * Un resolutor de mentira configurable: contesta con una A de verdad (con TTL) o se calla, tarda lo
 * que se le diga y puede contestar SERVFAIL. Cuenta lo que le llega y recuerda los nombres.
 */
class Srv(
    @Volatile var silent: Boolean = false,
    @Volatile var delayMs: Long = 0,
    @Volatile var ttl: Int = 300,
    @Volatile var servfail: Boolean = false,
) : AutoCloseable {
    val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
    val address = InetSocketAddress(InetAddress.getLoopbackAddress(), socket.localPort)
    val received = AtomicInteger()
    val names = CopyOnWriteArrayList<String>()

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
                DnsPacket.parseQuestion(query)?.let { names += it.name.lowercase() }
                if (silent) continue
                val reply = build(query)
                val to = p.socketAddress
                delayer.schedule({ runCatching { socket.send(DatagramPacket(reply, reply.size, to)) } }, delayMs, TimeUnit.MILLISECONDS)
            }
        }.apply { isDaemon = true; start() }
    }

    private fun build(query: ByteArray): ByteArray {
        val end = DnsPacket.parseQuestion(query)!!.end
        val out = ByteArrayOutputStream()
        out.write(query, 0, 2)
        if (servfail) {
            out.write(byteArrayOf(0x81.toByte(), 0x82.toByte(), 0, 1, 0, 0, 0, 0, 0, 0))
            out.write(query, 12, end - 12)
            return out.toByteArray()
        }
        out.write(byteArrayOf(0x81.toByte(), 0x80.toByte(), 0, 1, 0, 1, 0, 0, 0, 0))
        out.write(query, 12, end - 12)
        out.write(byteArrayOf(0xC0.toByte(), 0x0C, 0, 1, 0, 1))
        out.write(byteArrayOf((ttl shr 24).toByte(), (ttl shr 16).toByte(), (ttl shr 8).toByte(), ttl.toByte(), 0, 4))
        out.write(ip)
        return out.toByteArray()
    }

    override fun close() {
        socket.close()
        delayer.shutdownNow()
    }
}

/** Un transporte DNS-sobre-TLS de mentira: contesta en el acto (o tras [delayMs]) con una A de mentira. */
class FakeDot(
    private val onMessage: (ByteArray, InetSocketAddress) -> Unit,
    @Volatile var delayMs: Long = 0,
    @Volatile var accepting: Boolean = true,
) : DotTransport {
    override val servers = listOf(InetSocketAddress(InetAddress.getLoopbackAddress(), 853))
    val sent = AtomicInteger()
    val disconnects = AtomicInteger()
    private val ex = Executors.newSingleThreadScheduledExecutor()

    override fun send(query: ByteArray): Boolean {
        if (!accepting) return false
        sent.incrementAndGet()
        val q = query.copyOf()
        ex.schedule({
            val end = DnsPacket.parseQuestion(q)!!.end
            val out = ByteArrayOutputStream()
            out.write(q, 0, 2)
            out.write(byteArrayOf(0x81.toByte(), 0x80.toByte(), 0, 1, 0, 1, 0, 0, 0, 0))
            out.write(q, 12, end - 12)
            out.write(byteArrayOf(0xC0.toByte(), 0x0C, 0, 1, 0, 1, 0, 0, 1, 0x2C, 0, 4, 9, 9, 9, 9))
            runCatching { onMessage(out.toByteArray(), servers[0]) }
        }, delayMs, TimeUnit.MILLISECONDS)
        return true
    }

    override fun disconnect() {
        disconnects.incrementAndGet()
    }

    override fun close() {
        ex.shutdownNow()
    }
}
