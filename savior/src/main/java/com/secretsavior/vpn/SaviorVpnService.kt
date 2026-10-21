package com.secretsavior.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.data.Store
import com.secretsavior.guard.Watchdog
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.concurrent.Executors

/**
 * Filtro DNS local. No es una VPN de verdad: ningún dato viaja por un servidor
 * ajeno. Sólo declara un "servidor DNS" falso dentro de la subred del túnel y
 * enruta esa subred; el resto del tráfico sale por la red de siempre.
 *
 * Cada consulta que llega al túnel pasa por [DnsFilter]. Si el nombre está
 * bloqueado se contesta con 0.0.0.0; si no, se reenvía a un resolutor con
 * filtro familiar. No hay acción de "parar": este servicio sólo se detiene si el
 * sistema lo revoca, y entonces [Watchdog] lo vuelve a levantar.
 */
class SaviorVpnService : VpnService() {

    private var tun: ParcelFileDescriptor? = null
    private var reader: Thread? = null
    private val pool = Executors.newFixedThreadPool(6)
    private val writeLock = Any()

    /** Lo destruye el sistema: el hilo lector no debe llamar a stopSelf sobre un servicio ya relanzado. */
    @Volatile
    private var destroyed = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        start()
        return START_STICKY
    }

    private fun start() {
        if (running) return
        DnsFilter.extra = Store.extraDomains(this)
        val builder = Builder()
            .setSession("Secret Savior")
            .setMtu(1500)
            .addAddress(ADDRESS, 24)
            .addDnsServer(DNS)
            .addRoute(SUBNET, 24)
            .setConfigureIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        val established = try {
            builder.establish()
        } catch (e: Exception) {
            Log.w(TAG, "establish falló", e)
            null
        }
        val pfd = established ?: run {
            failures++
            stopSelf()
            return
        }
        failures = 0
        tun = pfd
        running = true
        reader = Thread({ loop(pfd) }, "savior-tun").also { it.start() }
    }

    private fun loop(pfd: ParcelFileDescriptor) {
        val input = FileInputStream(pfd.fileDescriptor)
        val output = FileOutputStream(pfd.fileDescriptor)
        val buf = ByteArray(32767)
        try {
            while (!Thread.currentThread().isInterrupted) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) handle(buf, n, output)
            }
        } catch (e: IOException) {
            // el túnel se cerró: salir del bucle es lo correcto
        } catch (e: Exception) {
            Log.w(TAG, "bucle del túnel", e)
        }
        if (!destroyed) stopSelf()
    }

    private fun handle(buf: ByteArray, n: Int, out: FileOutputStream) {
        if (n < 28 || (buf[0].toInt() and 0xF0) shr 4 != 4) return
        val ihl = (buf[0].toInt() and 0x0F) * 4
        if (n < ihl + 8) return
        for (i in 0..3) if (buf[16 + i] != DNS_BYTES[i]) return

        when (buf[9].toInt() and 0xFF) {
            IpPacket.PROTO_UDP -> {
                val port = ((buf[ihl + 2].toInt() and 0xFF) shl 8) or (buf[ihl + 3].toInt() and 0xFF)
                if (port != 53) return
                val udpLen = ((buf[ihl + 4].toInt() and 0xFF) shl 8) or (buf[ihl + 5].toInt() and 0xFF)
                val len = minOf(udpLen - 8, n - ihl - 8)
                if (len <= 0) return
                val header = buf.copyOf(ihl + 8)
                val query = buf.copyOfRange(ihl + 8, ihl + 8 + len)
                pool.execute { answer(header, ihl, query, out) }
            }

            IpPacket.PROTO_TCP -> IpPacket.tcpReset(buf, n, ihl)?.let { write(out, it) }
        }
    }

    private fun answer(header: ByteArray, ihl: Int, query: ByteArray, out: FileOutputStream) {
        try {
            val q = DnsPacket.parseQuestion(query)
            val reply = when {
                q != null && DnsFilter.isBlocked(q.name) -> {
                    if (q.type == DnsPacket.TYPE_A) Store.countBlock(this)
                    DnsPacket.blocked(query, q)
                }

                else -> forward(query) ?: q?.let { DnsPacket.servfail(query, it) }
            } ?: return
            write(out, IpPacket.udpReply(header, ihl, reply))
        } catch (e: Exception) {
            Log.w(TAG, "consulta DNS", e)
        }
    }

    private fun forward(query: ByteArray): ByteArray? {
        for (host in UPSTREAMS) {
            try {
                DatagramSocket().use { s ->
                    protect(s) // el reenvío no debe volver a entrar en el túnel
                    s.soTimeout = 2500
                    s.connect(InetSocketAddress(host, 53))
                    s.send(DatagramPacket(query, query.size))
                    val buf = ByteArray(4096)
                    val p = DatagramPacket(buf, buf.size)
                    s.receive(p)
                    return buf.copyOf(p.length)
                }
            } catch (e: IOException) {
                // probar el siguiente resolutor
            }
        }
        return null
    }

    private fun write(out: FileOutputStream, packet: ByteArray) {
        synchronized(writeLock) {
            try {
                out.write(packet)
            } catch (e: IOException) {
                // túnel cerrado mientras se contestaba
            }
        }
    }

    override fun onRevoke() {
        // Otra VPN tomó el relevo. El sistema detiene el servicio; onDestroy se encarga del resto.
        super.onRevoke()
    }

    override fun onDestroy() {
        destroyed = true
        running = false
        reader?.interrupt()
        pool.shutdownNow()
        try {
            tun?.close()
        } catch (e: IOException) {
            // ya estaba cerrado
        }
        tun = null
        // Si fue el sistema quien nos paró, volver. Si ya no hay permiso, pedirlo. Si el
        // túnel ni siquiera se pudo crear, esperar más: reintentar cada segundo sólo gasta batería.
        val app = applicationContext
        Handler(Looper.getMainLooper()).postDelayed({
            if (!Watchdog.ensure(app)) Watchdog.nag(app)
        }, if (failures > 0) 30_000L else 1_500L)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SecretSavior"

        /** Subred del túnel. El "servidor DNS" es .1 y el teléfono es .2. */
        private const val SUBNET = "10.255.255.0"
        private const val ADDRESS = "10.255.255.2"
        private const val DNS = "10.255.255.1"
        private val DNS_BYTES = byteArrayOf(10, -1, -1, 1)

        /**
         * Resolutores con filtro familiar, en orden. CleanBrowsing "Adult Filter"
         * bloquea pornografía, proxies/VPN de evasión y sitios mixtos, y fuerza
         * búsqueda segura en Google, Bing y YouTube. Cloudflare for Families
         * (1.1.1.3) queda de reserva.
         */
        val UPSTREAMS = listOf("185.228.168.10", "185.228.169.11", "1.1.1.3", "1.0.0.3")

        @Volatile
        var running = false
            private set

        /** Intentos seguidos en que establish() no dio túnel. */
        @Volatile
        private var failures = 0
    }
}
