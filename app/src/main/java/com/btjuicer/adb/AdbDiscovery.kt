package com.btjuicer.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

data class Endpoint(val host: String, val port: Int) {
    override fun toString(): String = "$host:$port"
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
    }

    private val nsd: NsdManager?
        get() = context.getSystemService(Context.NSD_SERVICE) as? NsdManager

    /**
     * @return the first endpoint of [serviceType], or null if none showed up in
     *   time. Never throws: a failure here is a normal outcome the UI explains.
     */
    suspend fun find(serviceType: String, timeoutMs: Long): Endpoint? {
        val manager = nsd ?: return null
        val lock = acquireMulticastLock()
        return try {
            withTimeout(timeoutMs) { discover(manager, serviceType) }
        } catch (_: TimeoutCancellationException) {
            null
        } catch (t: Throwable) {
            Log.w(TAG, "mDNS discovery failed for $serviceType", t)
            null
        } finally {
            runCatching { lock?.release() }
        }
    }

    private suspend fun discover(manager: NsdManager, serviceType: String): Endpoint? =
        suspendCancellableCoroutine { continuation ->
            var settled = false

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
                            val port = serviceInfo.port
                            if (port <= 0) return
                            if (settled) return
                            settled = true
                            continuation.resume(Endpoint(host, port))
                        }
                    },
                )
            }

            val listener = object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                    if (settled) return
                    settled = true
                    Log.w(TAG, "discovery start failed: $errorCode")
                    continuation.resume(null)
                }

                override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

                override fun onDiscoveryStarted(serviceType: String?) = Unit

                override fun onDiscoveryStopped(serviceType: String?) = Unit

                override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                    serviceInfo?.let(::resolve)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo?) = Unit
            }

            continuation.invokeOnCancellation {
                runCatching { manager.stopServiceDiscovery(listener) }
            }

            runCatching {
                manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
            }.onFailure {
                if (!settled) {
                    settled = true
                    continuation.resume(null)
                }
            }
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
