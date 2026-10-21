package com.secretsavior.vpn

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.data.Store
import com.secretsavior.guard.Notice
import com.secretsavior.guard.Watchdog
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.InetSocketAddress

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
    @Volatile
    private var forwarder: DnsForwarder? = null
    private val writeLock = Any()

    /** Lo destruye el sistema: el hilo lector no debe llamar a stopSelf sobre un servicio ya relanzado. */
    @Volatile
    private var destroyed = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        start()
        return START_STICKY
    }

    /** Sin esto el sistema mata el proceso en cuanto la app se cierra o falta memoria. */
    private fun goForeground() {
        try {
            val n = Notice.build(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(Notice.ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(Notice.ID, n)
            }
        } catch (e: Exception) {
            // Android puede negarlo desde segundo plano; el filtro funciona igual, con menos blindaje.
            Log.w(TAG, "sin primer plano", e)
        }
    }

    /** Al deslizar la app fuera de Recientes, algunos fabricantes matan el proceso: volver enseguida. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Watchdog.schedule(applicationContext, 1_000L)
        super.onTaskRemoved(rootIntent)
    }

    private fun start() {
        if (running) return
        DnsFilter.extra = Store.extraDomains(this)
        val builder = Builder()
            .setSession("Secret Savior")
            .setMtu(1500)
            // Por defecto el descriptor del túnel es no bloqueante: read() devuelve 0 al
            // instante si no hay nada y el bucle lector giraría sin parar con un núcleo al 100 %.
            .setBlocking(true)
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
        forwarder = try {
            DnsForwarder(PRIMARY, FALLBACK, protect = { protect(it) })
        } catch (e: IOException) {
            Log.w(TAG, "sin socket de reenvío", e)
            null
        }
        tun = pfd
        current = this
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
                if (n > 0) handle(buf, n, output) else Thread.sleep(IDLE_MS) // por si acaso
            }
        } catch (e: InterruptedException) {
            // onDestroy: salir
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
                answer(header, ihl, query, out)
            }

            IpPacket.PROTO_TCP -> IpPacket.tcpReset(buf, n, ihl)?.let { write(out, it) }
        }
    }

    /**
     * Lo bloqueado se contesta aquí mismo, sin salir del teléfono. Lo demás se entrega al
     * reenviador, que no bloquea este hilo: el lector del túnel sigue leyendo mientras
     * las respuestas llegan.
     */
    private fun answer(header: ByteArray, ihl: Int, query: ByteArray, out: FileOutputStream) {
        val q = DnsPacket.parseQuestion(query)
        if (q != null && DnsFilter.isBlocked(q.name)) {
            if (q.type == DnsPacket.TYPE_A) Store.countBlock(this)
            write(out, IpPacket.udpReply(header, ihl, DnsPacket.blocked(query, q)))
            return
        }
        val fwd = forwarder ?: return
        fwd.query(query) { response ->
            val reply = response ?: q?.let { DnsPacket.servfail(query, it) }
            if (reply != null) write(out, IpPacket.udpReply(header, ihl, reply))
        }
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
        if (current === this) current = null
        reader?.interrupt()
        forwarder?.close()
        forwarder = null
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
        private const val IDLE_MS = 20L

        /** Subred del túnel. El "servidor DNS" es .1 y el teléfono es .2. */
        private const val SUBNET = "10.255.255.0"
        private const val ADDRESS = "10.255.255.2"
        private const val DNS = "10.255.255.1"
        private val DNS_BYTES = byteArrayOf(10, -1, -1, 1)

        /**
         * CleanBrowsing "Adult Filter": bloquea pornografía y contenido explícito y fuerza
         * búsqueda segura en Google y Bing. Deja pasar sitios mixtos como Reddit (para eso
         * está el guardián). Se pregunta a todos a la vez y gana el primero.
         *
         * Van también las direcciones IPv6: en redes móviles sólo IPv6 (muchas lo son) la
         * IPv4 pasa por una traducción (464XLAT) que añade latencia. Donde no hay IPv6, el
         * envío falla al instante y no cuesta nada.
         */
        val PRIMARY = listOf(
            dns("185.228.168.10"), dns("185.228.169.11"),
            dns("2a0d:2a00:1::1"), dns("2a0d:2a00:2::1"),
        )

        /** Cloudflare for Families (malware y adultos), sólo si CleanBrowsing no contesta. */
        val FALLBACK = listOf(
            dns("1.1.1.3"), dns("1.0.0.3"),
            dns("2606:4700:4700::1113"), dns("2606:4700:4700::1003"),
        )

        /** Tiempo medio de respuesta del DNS en ms, o null si el filtro no corre. */
        val dnsAverageMs: Long?
            get() = current?.forwarder?.takeIf { it.answered > 0 }?.averageMs

        @Volatile
        private var current: SaviorVpnService? = null

        private fun dns(ip: String) = InetSocketAddress(ip, 53)

        @Volatile
        var running = false
            private set

        /** Intentos seguidos en que establish() no dio túnel. */
        @Volatile
        private var failures = 0
    }
}
