package com.secretsavior.vpn

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.data.Store
import com.secretsavior.guard.Notice
import com.secretsavior.guard.Watchdog
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

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
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** Los bytes de la dirección del "servidor DNS" de este túnel (la subred se elige al arrancar). */
    @Volatile
    private var dnsBytes = Subnets.CANDIDATES.first().dnsBytes

    private val pipeline = DnsPipeline({ forwarder }, { Store.countBlock(this) })

    /** Barrido de conexiones DNS-sobre-TCP inactivas; el hilo sólo existe mientras las hay. */
    @Volatile
    private var sweeper: ScheduledThreadPoolExecutor? = null

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
        // Con las direcciones IPv6 de los resolutores públicos; si el sistema las rechaza (algún
        // fabricante), un segundo intento sin ellas: el filtro por IPv4 es lo imprescindible.
        var established: ParcelFileDescriptor? = null
        for (withV6 in booleanArrayOf(true, false)) {
            established = try {
                buildTunnel(subnet, withV6).establish()
            } catch (e: Exception) {
                Log.w(TAG, "establish falló (v6=$withV6)", e)
                null
            }
            if (established != null) break
        }
        val pfd = established ?: run {
            failures++
            stopSelf()
            return
        }
        val fwd = try {
            DnsForwarder(
                PRIMARY, FALLBACK,
                protect = { protect(it) },
                protectTcp = { protect(it) },
                // El receptor es quien entrega cada respuesta: que no pierda la CPU frente a segundo plano.
                onThreadStart = { try { Process.setThreadPriority(Process.THREAD_PRIORITY_FOREGROUND) } catch (e: Exception) { } },
            )
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
        watchNetworks()
        reader = Thread({ loop(pfd) }, "savior-tun").also { it.start() }
    }

    private fun buildTunnel(subnet: Subnets.Candidate, withV6: Boolean): Builder {
        val builder = Builder()
            .setSession("Secret Savior")
            .setMtu(1500)
            // Por defecto el descriptor del túnel es no bloqueante: read() devuelve 0 al
            // instante si no hay nada y el bucle lector giraría sin parar con un núcleo al 100 %.
            .setBlocking(true)
            .addAddress(subnet.address, 24)
            .addDnsServer(subnet.dns)
            .addRoute(subnet.network, 24)
            // Imprescindible. Este túnel sólo declara IPv4, y Android, ante una VPN sin nada de
            // una familia, da por hecho que no la soporta y BLOQUEA todo el tráfico de esa
            // familia: sin esta línea ninguna app del teléfono puede usar IPv6. En redes móviles
            // sólo IPv6 eso manda todo por la traducción a IPv4 (464XLAT), más lenta.
            .allowFamily(OsConstants.AF_INET)
            .allowFamily(OsConstants.AF_INET6)
            .setConfigureIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        // DNS público por IP (DoH/DoT/DNS clásico): al túnel, donde se filtra o se rechaza.
        // Rutas sueltas, nunca por defecto: el resto del tráfico sigue su camino normal.
        // IPv6 necesita una dirección propia para poder declarar rutas: una ULA fija (RFC 4193,
        // no enrutable en internet) que no se usa para nada más. Sin ruta ni DNS v6 por defecto.
        if (withV6) builder.addAddress(TUN_ULA, 64)
        for (r in resolverTable.routes) {
            if (r.v6 && !withV6) continue
            try {
                builder.addRoute(r.inet, r.prefix)
            } catch (e: Exception) {
                Log.w(TAG, "ruta rechazada", e) // una ruta de más no vale un túnel caído
            }
        }
        excludeFromTunnel(builder)
        return builder
    }

    /**
     * Netflix (y en general cualquier app que compruebe si hay una VPN activa, como algunos
     * bancos) se niega a funcionar aunque ésta no toque su tráfico: sólo filtra DNS. Android no
     * distingue una VPN que reenvía todo de una que sólo captura DNS, así que la única forma de
     * que una app no la vea es que su tráfico no pase por el túnel en absoluto. Para las apps de
     * [EXCLUDED_APPS], DNS incluido, sale por la red real: el filtro de contenido no les llega,
     * pero ninguna de ellas es una vía de pornografía. Prime Video no necesita esto: no detecta
     * la VPN.
     */
    private fun excludeFromTunnel(builder: Builder) {
        for (pkg in EXCLUDED_APPS) {
            try {
                builder.addDisallowedApplication(pkg)
            } catch (e: PackageManager.NameNotFoundException) {
                // no está instalada: nada que excluir
            }
        }
    }

    /**
     * Avisa al reenviador cuando cambia la red real (Wi-Fi a datos y al revés). Las VPN se
     * excluyen: la nuestra no cuenta. Al registrarse, onAvailable se llama una vez por cada red que
     * ya existe; es inofensivo (caché sin nada caducado que olvidar y ninguna consulta en vuelo).
     */
    private fun watchNetworks() {
        try {
            val cm = getSystemService(ConnectivityManager::class.java) ?: return
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    forwarder?.onNetworkChanged()
                }

                override fun onLost(network: Network) {
                    forwarder?.onNetworkChanged()
                }
            }
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            cm.registerNetworkCallback(request, cb)
            networkCallback = cb
        } catch (e: Exception) {
            Log.w(TAG, "sin aviso de cambios de red", e)
        }
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
        // Todas las conexiones del teléfono esperan a este hilo para resolver su DNS: no puede
        // perder la CPU frente a trabajo en segundo plano.
        try { Process.setThreadPriority(Process.THREAD_PRIORITY_FOREGROUND) } catch (e: Exception) { }
        val input = FileInputStream(pfd.fileDescriptor)
        val output = FileOutputStream(pfd.fileDescriptor)
        val tcp = TcpDns(
            send = { write(output, it) },
            resolve = { q, done -> pipeline.resolve(q, done) },
            schedule = { delay, task -> scheduleSweep(delay, task) },
        )
        val buf = ByteArray(32767)
        try {
            while (!Thread.currentThread().isInterrupted) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) {
                    try {
                        handle(buf, n, output, tcp)
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

    private fun scheduleSweep(delayMs: Long, task: Runnable) {
        if (destroyed) return
        val ex = sweeper ?: synchronized(this) {
            sweeper ?: ScheduledThreadPoolExecutor(1) { r -> Thread(r, "savior-tcp-sweep").apply { isDaemon = true } }
                .apply {
                    setKeepAliveTime(10, TimeUnit.SECONDS)
                    allowCoreThreadTimeOut(true)
                }.also { sweeper = it }
        }
        try {
            ex.schedule(task, delayMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            // cerrándose el servicio
        }
    }

    /**
     * Al túnel sólo llegan paquetes para la dirección del "servidor DNS" propio y para las de
     * [resolverTable]. Primero una comprobación sin asignar nada (el 99 % de lo que se lee); sólo
     * lo que de verdad nos toca se analiza.
     */
    private fun handle(buf: ByteArray, n: Int, out: FileOutputStream, tcp: TcpDns) {
        val own: Boolean
        val captured: Boolean
        when ((buf[0].toInt() and 0xF0) shr 4) {
            4 -> {
                if (n < 28) return
                val dns = dnsBytes
                own = buf[16] == dns[0] && buf[17] == dns[1] && buf[18] == dns[2] && buf[19] == dns[3]
                captured = !own && resolverTable.containsV4(
                    ((buf[16].toInt() and 0xFF) shl 24) or ((buf[17].toInt() and 0xFF) shl 16) or
                        ((buf[18].toInt() and 0xFF) shl 8) or (buf[19].toInt() and 0xFF),
                )
            }
            6 -> {
                if (n < 48) return
                own = false
                captured = resolverTable.containsV6(Resolvers.long(buf, 24), Resolvers.long(buf, 32))
            }
            else -> return
        }
        if (!own && !captured) return
        val p = IpPacket.parse(buf, n) ?: return

        when (p.proto) {
            IpPacket.PROTO_UDP -> {
                if (p.l4Len < 8 || n < p.l4 + 8) return
                val port = IpPacket.u16(buf, p.l4 + 2)
                if (port != 53) {
                    // QUIC (443) o DNS-sobre-QUIC (853) a un resolutor público: "puerto inaccesible"
                    // y la app vuelve a TCP/DNS normal al instante. Al DNS propio no se contesta.
                    if (captured) IpPacket.icmpPortUnreachable(buf, n, p)?.let { write(out, it) }
                    return
                }
                val len = minOf(IpPacket.u16(buf, p.l4 + 4) - 8, n - p.l4 - 8)
                if (len <= 0) return
                val header = buf.copyOf(p.l4 + 8)
                val query = buf.copyOfRange(p.l4 + 8, p.l4 + 8 + len)
                pipeline.resolve(query) { reply ->
                    if (reply != null) write(out, IpPacket.udpReply(header, p, reply))
                }
            }

            IpPacket.PROTO_TCP -> {
                if (p.l4Len < 20 || n < p.l4 + 20) return
                // 53: un servidor DNS de verdad. 853 (DoT) y 443 (DoH) y todo lo demás: RST, para
                // que Android y los navegadores vuelvan al DNS normal sin esperar.
                if (IpPacket.u16(buf, p.l4 + 2) == 53) tcp.onPacket(buf, n, p)
                else IpPacket.tcpReset(buf, n, p)?.let { write(out, it) }
            }

            IpPacket.PROTO_ICMP, IpPacket.PROTO_ICMP6 ->
                IpPacket.icmpEchoReply(buf, n, p)?.let { write(out, it) }
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
        Store.flushNow(this)
        if (current === this) current = null
        reader?.interrupt()
        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                // no estaba registrado
            }
        }
        networkCallback = null
        sweeper?.shutdownNow()
        sweeper = null
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
                // Con la caché casi todo se contesta sin salir a la red: hay datos aunque recentTotal sea 0.
                if (it.recentTotal == 0 && it.cacheLookups == 0) null
                else DnsHealth(it.averageMs, it.recentTotal, it.recentFailed, it.cacheHits, it.cacheLookups)
            }

        data class DnsHealth(
            val averageMs: Long,
            val recentTotal: Int,
            val recentFailed: Int,
            val cacheHits: Int = 0,
            val cacheLookups: Int = 0,
        ) {
            /** Porcentaje de consultas contestadas desde la caché; null con pocas para que no bailen las cifras. */
            val cachePercent: Int? get() = if (cacheLookups < 20) null else cacheHits * 100 / cacheLookups

            /** Más de la mitad de las últimas consultas sin respuesta: algo impide llegar a los resolutores. */
            val broken get() = recentTotal >= 10 && recentFailed * 2 >= recentTotal
        }

        @Volatile
        private var current: SaviorVpnService? = null

        private fun dns(ip: String) = InetSocketAddress(ip, 53)

        /** Apps que se niegan a funcionar si ven cualquier VPN activa, sea cual sea su propósito. */
        val EXCLUDED_APPS = listOf("com.netflix.mediaclient")

        @Volatile
        var running = false
            private set

        /**
         * Si el sistema la tiene como «VPN siempre activa» (Android 10+); null si no se sabe. Se
         * pregunta al servicio vivo cada vez: activarla en Ajustes no reinicia el servicio, y
         * guardarla sólo al arrancar la dejaría siempre desactualizada.
         */
        val alwaysOn: Boolean?
            get() = ask { it.isAlwaysOn }

        /** «Bloquear conexiones sin VPN» (Android 10+); null si no se sabe. También en vivo. */
        val lockdown: Boolean?
            get() = ask { it.isLockdownEnabled }

        private fun ask(f: (SaviorVpnService) -> Boolean): Boolean? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
            val svc = current ?: return null
            return try {
                f(svc)
            } catch (e: Exception) {
                null // algún fabricante lo rechaza; "no se sabe" no bloquea a nadie
            }
        }

        /** Resolutores públicos a capturar: todos menos los aguas arriba de [PRIMARY] y [FALLBACK]. */
        private val resolverTable: Resolvers.Table by lazy {
            Resolvers.build((PRIMARY + FALLBACK).mapNotNull { it.address })
        }

        /** Dirección ULA (RFC 4193) del túnel: sólo existe para poder declarar rutas IPv6. */
        private const val TUN_ULA = "fd53:5a76:7230::2"

        /** Intentos seguidos en que establish() no dio túnel. */
        @Volatile
        private var failures = 0
    }
}
