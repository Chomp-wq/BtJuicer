package com.secretsavior.vpn

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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
import java.net.Inet4Address
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

    /** Los bytes de la dirección del "servidor DNS" de este túnel (la subred se elige al arrancar). */
    @Volatile
    private var dnsBytes = Subnets.CANDIDATES.first().dnsBytes

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
        val subnet = chooseSubnet()
        val builder = Builder()
            .setSession("Secret Savior")
            .setMtu(1500)
            // Por defecto el descriptor del túnel es no bloqueante: read() devuelve 0 al
            // instante si no hay nada y el bucle lector giraría sin parar con un núcleo al 100 %.
            .setBlocking(true)
            .addAddress(subnet.address, 24)
            .addDnsServer(subnet.dns)
            .addRoute(subnet.network, 24)
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
        val fwd = try {
            DnsForwarder(PRIMARY, FALLBACK, protect = { protect(it) }, protectTcp = { protect(it) })
        } catch (e: IOException) {
            null
        }
        if (fwd == null) {
            // Un túnel sin reenviador se tragaría todas las consultas y el teléfono se quedaría sin
            // DNS con la VPN "activa". Mejor no levantarlo y reintentar más tarde.
            Log.w(TAG, "sin socket de reenvío")
            try {
                pfd.close()
            } catch (e: IOException) {
                // ya estaba cerrado
            }
            failures++
            stopSelf()
            return
        }
        failures = 0
        forwarder = fwd
        dnsBytes = subnet.dnsBytes
        tun = pfd
        current = this
        running = true
        reader = Thread({ loop(pfd) }, "savior-tun").also { it.start() }
    }

    /**
     * La subred del túnel no puede coincidir con la de la red real: con el túnel encima, el
     * teléfono dejaría de ver a su propio router (y sin él, sin Wi-Fi). Se elige una que no se
     * pise con ninguna red en uso; casi siempre es la de siempre.
     */
    private fun chooseSubnet(): Subnets.Candidate {
        val used = ArrayList<Pair<Int, Int>>()
        try {
            val cm = getSystemService(ConnectivityManager::class.java) ?: return Subnets.CANDIDATES.first()
            @Suppress("DEPRECATION")
            for (network in cm.allNetworks) {
                // Las VPN no cuentan: la nuestra de antes (si la hay) se sustituye, y otra se revoca.
                if (cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) continue
                val lp = cm.getLinkProperties(network) ?: continue
                for (la in lp.linkAddresses) {
                    (la.address as? Inet4Address)?.let { used += Subnets.toInt(it.address) to la.prefixLength }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    for (r in lp.routes) {
                        val d = r.destination
                        (d.address as? Inet4Address)?.let { used += Subnets.toInt(it.address) to d.prefixLength }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo mirar las redes", e)
        }
        return Subnets.pick(used)
    }

    private fun loop(pfd: ParcelFileDescriptor) {
        val input = FileInputStream(pfd.fileDescriptor)
        val output = FileOutputStream(pfd.fileDescriptor)
        val buf = ByteArray(32767)
        try {
            while (!Thread.currentThread().isInterrupted) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) {
                    try {
                        handle(buf, n, output)
                    } catch (e: Exception) {
                        // Un paquete raro no puede tumbar el túnel: se rehace con un parón de
                        // todas las conexiones del teléfono (cada VPN nueva las corta).
                        Log.w(TAG, "paquete descartado", e)
                    }
                } else {
                    Thread.sleep(IDLE_MS) // por si acaso
                }
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
        val dns = dnsBytes
        for (i in 0..3) if (buf[16 + i] != dns[i]) return

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
        val fwd = forwarder
        if (fwd == null) {
            // No debería pasar; si pasa, un error al momento es mejor que 5 s de espera por consulta.
            q?.let { write(out, IpPacket.udpReply(header, ihl, DnsPacket.servfail(query, it))) }
            return
        }
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

        /** Cómo va el DNS, o null si el filtro no corre o aún no ha contestado nada. */
        val dnsHealth: DnsHealth?
            get() = current?.forwarder?.let {
                if (it.recentTotal == 0) null else DnsHealth(it.averageMs, it.recentTotal, it.recentFailed)
            }

        data class DnsHealth(val averageMs: Long, val recentTotal: Int, val recentFailed: Int) {
            /** Más de la mitad de las últimas consultas sin respuesta: algo impide llegar a los resolutores. */
            val broken get() = recentTotal >= 10 && recentFailed * 2 >= recentTotal
        }

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
