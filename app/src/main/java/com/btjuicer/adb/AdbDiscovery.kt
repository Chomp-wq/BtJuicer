package com.btjuicer.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

data class Endpoint(val host: String, val port: Int) {
    override fun toString(): String = "$host:$port"

    companion object {
        /**
         * Reads `192.168.1.40:37103` as typed off the wireless-debugging screen.
         *
         * The escape hatch for when mDNS is useless — a network with multicast
         * filtered, or a cache that will not let go of an old record. The screen
         * that shows the number is two taps away, so an app that cannot discover
         * should at least let you tell it.
         */
        fun parse(text: String): Endpoint? {
            val trimmed = text.trim().removePrefix("adb connect ").trim()
            val host = trimmed.substringBeforeLast(':', "").trim()
            val port = trimmed.substringAfterLast(':', "").trim().toIntOrNull()
            if (host.isEmpty() || port == null || port !in 1..65_535) return null
            return Endpoint(host, port)
        }
    }
}

/**
 * Finds the phone's own ADB endpoints over mDNS.
 *
 * Wireless debugging advertises two services: the pairing port (which only
 * exists while the "Pair device with pairing code" dialog is open, and changes
 * every time) and the connect port (which changes on every reboot). Asking the
 * user to read numbers off a settings screen and type them in is exactly the
 * kind of friction this app is supposed to remove, so we discover them instead.
 */
class AdbDiscovery(private val context: Context) {

    companion object {
        const val PAIRING_TYPE = "_adb-tls-pairing._tcp"
        const val CONNECT_TYPE = "_adb-tls-connect._tcp"

        private const val TAG = "BTJuicerAdb"

        /** The daemon is on this phone, so this address always reaches it. */
        private const val LOOPBACK = "127.0.0.1"

        /** How long to keep listening after the last new endpoint appeared. */
        private const val SETTLE_MS = 2_500L
        private const val POLL_MS = 200L
    }

    private val nsd: NsdManager?
        get() = context.getSystemService(Context.NSD_SERVICE) as? NsdManager

    /**
     * Every endpoint of [serviceType] that answers within the window.
     *
     * **All of them, not the first.** Android keeps an mDNS cache, and a service
     * that no longer exists is still announced from it — arriving *before* the
     * live one precisely because it needs no round trip. Taking the first answer
     * therefore prefers the stale one, which is how this ended up handing out an
     * IP and port from a previous session and failing to connect to them
     * forever. Whoever calls this is expected to try each in turn: a dead
     * endpoint refuses the connection immediately, so the cost of being wrong is
     * a few milliseconds.
     *
     * Never throws; an empty list is a normal outcome the UI explains.
     */
    suspend fun findAll(serviceType: String, timeoutMs: Long): List<Endpoint> {
        val manager = nsd
        val discovered = if (manager == null) {
            emptyList()
        } else {
            val lock = acquireMulticastLock()
            try {
                collect(manager, serviceType, timeoutMs)
            } catch (t: Throwable) {
                if (t is CancellationException) throw t
                Log.w(TAG, "mDNS discovery failed for $serviceType", t)
                emptyList()
            } finally {
                runCatching { lock?.release() }
            }
        }
        return withLoopback(discovered, serviceType)
    }

    /**
     * Adds the addresses mDNS cannot give us.
     *
     * The daemon we are dialling runs on *this phone*, so the loopback address
     * always reaches it — adbd binds its listener to every interface, not just
     * the Wi-Fi one. That makes `127.0.0.1` immune to the two things that break
     * discovery: a network where multicast is filtered, and a cached record
     * holding a Wi-Fi address the phone no longer has. Only the port is ever
     * genuinely unknown.
     *
     * And the port is often not unknown either: adbd publishes it in a system
     * property. Reading it skips mDNS altogether, which is why it is tried
     * first — it is the only source here that cannot be stale.
     */
    private fun withLoopback(discovered: List<Endpoint>, serviceType: String): List<Endpoint> {
        val ordered = LinkedHashSet<Endpoint>()

        if (serviceType == CONNECT_TYPE) {
            propertyPort()?.let {
                Log.i(TAG, "adbd port from system property: $it")
                ordered += Endpoint(LOOPBACK, it)
            }
        }
        ordered += discovered
        // Every port we saw, retried against loopback: a stale record often has
        // the right port behind a wrong address.
        discovered.forEach { ordered += Endpoint(LOOPBACK, it.port) }

        return ordered.toList()
    }

    /**
     * The connect port, straight from adbd.
     *
     * `SystemProperties` is not in the public SDK, hence the reflection — and
     * hence [HiddenApi], which the connection path has already lifted by the
     * time this runs. Whether an ordinary app is allowed to read this particular
     * property depends on the ROM's SELinux policy, so it is a bonus and never
     * the only plan.
     */
    private fun propertyPort(): Int? = runCatching {
        val get = Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java, String::class.java)
        (get.invoke(null, "service.adb.tls.port", "") as? String)?.trim()?.toIntOrNull()
    }.getOrNull()?.takeIf { it in 1..65_535 }

    private suspend fun collect(
        manager: NsdManager,
        serviceType: String,
        timeoutMs: Long,
    ): List<Endpoint> {
        val found = LinkedHashSet<Endpoint>()
        var firstAt = 0L

        fun record(endpoint: Endpoint) = synchronized(found) {
            if (found.add(endpoint)) {
                Log.i(TAG, "mDNS $serviceType -> $endpoint")
                if (firstAt == 0L) firstAt = System.currentTimeMillis()
            }
        }

        // resolveService is one-shot per listener instance, so a fresh one is
        // created for every service the discovery turns up.
        fun resolve(info: NsdServiceInfo) {
            manager.resolveService(
                info,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                        Log.w(TAG, "resolve failed: $errorCode")
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                        @Suppress("DEPRECATION")
                        val host = serviceInfo?.host?.hostAddress ?: return
                        if (serviceInfo.port > 0) record(Endpoint(host, serviceInfo.port))
                    }
                },
            )
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.w(TAG, "discovery start failed: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

            override fun onDiscoveryStarted(serviceType: String?) = Unit

            override fun onDiscoveryStopped(serviceType: String?) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let(::resolve)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) = Unit
        }

        runCatching {
            manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure { return emptyList() }

        try {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                delay(POLL_MS)
                // Stop early once the announcements have gone quiet: the live
                // service usually turns up a beat after the cached one, so
                // leaving after the first answer is what caused the bug.
                val quiet = synchronized(found) {
                    firstAt != 0L && System.currentTimeMillis() - firstAt >= SETTLE_MS
                }
                if (quiet) break
            }
        } finally {
            runCatching { manager.stopServiceDiscovery(listener) }
        }
        return synchronized(found) { found.toList() }
    }

    /**
     * Some devices drop multicast packets to save power unless something is
     * holding this lock, which makes mDNS look broken rather than idle.
     */
    private fun acquireMulticastLock(): WifiManager.MulticastLock? = runCatching {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        wifi?.createMulticastLock("btjuicer-mdns")?.apply {
            setReferenceCounted(true)
            acquire()
        }
    }.getOrNull()
}
