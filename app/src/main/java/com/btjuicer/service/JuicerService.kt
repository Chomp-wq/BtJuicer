package com.btjuicer.service

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.btjuicer.Juicer
import com.btjuicer.adb.AdbState
import com.btjuicer.adb.LdacQuality
import com.btjuicer.bt.Route
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Keeps the equaliser attached and honest.
 *
 * Two jobs. First, re-apply the curve whenever the audio route changes: several
 * ROMs detach global-session effects when the output switches between speaker
 * and Bluetooth, and an EQ that silently stops working is worse than none.
 * Second, notice when a Bluetooth output connects — the moment Android is prone
 * to having dropped the LDAC quality setting — and offer the shortcut.
 */
class JuicerService : LifecycleService() {

    companion object {
        const val ACTION_START = "com.btjuicer.action.START"
        const val ACTION_STOP = "com.btjuicer.action.STOP"
        const val ACTION_TOGGLE_EQ = "com.btjuicer.action.TOGGLE_EQ"
        const val ACTION_REFRESH = "com.btjuicer.action.REFRESH"

        /** The route settles a beat after the callback fires. */
        private const val ROUTE_SETTLE_MS = 700L

        /** Codec poll cadence. Each read crosses an ADB socket and runs a full
         *  dumpsys, so anything faster costs battery without showing more. */
        private const val CODEC_POLL_MS = 10_000L

        /** Long enough for the A2DP link to finish negotiating on its own. */
        private const val CODEC_SETTLE_MS = 4_000L

        /** First wait before re-dialling a link that dropped. */
        private const val RETRY_BASE_MS = 15_000L
        private const val RETRY_MAX_MS = 300_000L

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, JuicerService::class.java).setAction(ACTION_START),
            )
        }

        fun stop(context: Context) {
            context.startService(Intent(context, JuicerService::class.java).setAction(ACTION_STOP))
        }
    }

    private val routeCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = onRouteChanged()

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = onRouteChanged()
    }

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED) return
            if (intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1) != BluetoothProfile.STATE_CONNECTED) return

            val device = IntentCompat.getParcelableExtra(
                intent,
                BluetoothDevice.EXTRA_DEVICE,
                BluetoothDevice::class.java,
            )
            val name = runCatching { device?.name.orEmpty() }.getOrDefault("")
            applyProfileFor(device?.address)
            reapplyCodecFor(device?.address)
            onRouteChanged()
            if (Juicer.prefs.current.remindOnConnect) {
                Notifications.remindChecklist(this@JuicerService, name)
            }
        }
    }

    private var codecJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        Juicer.init(this)
        Notifications.ensureChannels(this)
        Juicer.link.start()
        Juicer.link.registerRouteCallback(routeCallback)

        ContextCompat.registerReceiver(
            this,
            bluetoothReceiver,
            IntentFilter(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        // Must happen on every start path and within a few seconds, or the
        // system kills us for not going foreground in time.
        goForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                Juicer.engine.release()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_TOGGLE_EQ -> {
                val eq = Juicer.prefs.current.eq
                Juicer.prefs.setEq(eq.copy(enabled = !eq.enabled))
                Juicer.engine.apply(Juicer.prefs.current.eq)
                goForeground()
            }

            else -> {
                Juicer.engine.apply(Juicer.prefs.current.eq)
                onRouteChanged()
            }
        }
        startCodecPolling()
        return START_STICKY
    }

    override fun onDestroy() {
        codecJob?.cancel()
        runCatching { unregisterReceiver(bluetoothReceiver) }
        Juicer.link.unregisterRouteCallback(routeCallback)
        Juicer.link.stop()
        super.onDestroy()
    }

    /**
     * Keeps the ADB link up and the codec reading fresh.
     *
     * ### Why it now reconnects on its own
     *
     * It used not to, on the reasoning that reopening a debugging channel is the
     * user's decision. That reasoning holds for the *first* connection and not
     * for this one. The socket dies on its own — a Wi-Fi power-save nap, a
     * roamed access point, a codec change shaking the shared 2.4 GHz radio — and
     * when it does, nothing about the user's intent has changed. Making them
     * notice and press a button to restore a connection they already asked for
     * is not respecting a decision, it is forgetting one.
     *
     * So: only ever after a connection the user established, only while they
     * have not disconnected, and with a backoff that gives up to a five-minute
     * spacing rather than hammering mDNS.
     */
    private fun startCodecPolling() {
        if (codecJob?.isActive == true) return
        codecJob = lifecycleScope.launch {
            var failures = 0
            var nextAttemptAt = 0L

            while (isActive) {
                val state = Juicer.adb.state.value
                when {
                    state is AdbState.Connected -> {
                        failures = 0
                        nextAttemptAt = 0L
                        if (Juicer.prefs.current.pollCodec) {
                            runCatching { Juicer.codec.refresh() }
                        } else {
                            // Something has to cross the socket now and then, or
                            // a link nobody uses is a link nobody notices dying.
                            runCatching { Juicer.adb.shell("true") }
                        }
                    }

                    // Working means a connection attempt is already in flight.
                    state is AdbState.Working -> Unit

                    Juicer.prefs.current.adbAutoConnect &&
                        System.currentTimeMillis() >= nextAttemptAt -> {
                        val ok = runCatching { Juicer.adb.connect().isSuccess }.getOrDefault(false)
                        if (ok) {
                            failures = 0
                            nextAttemptAt = 0L
                            runCatching { Juicer.codec.refresh() }
                        } else {
                            failures++
                            nextAttemptAt = System.currentTimeMillis() + backoffMs(failures)
                        }
                    }
                }
                delay(CODEC_POLL_MS)
            }
        }
    }

    /** 15 s, then doubling, capped at five minutes. */
    private fun backoffMs(failures: Int): Long =
        (RETRY_BASE_MS shl (failures - 1).coerceIn(0, 5)).coerceAtMost(RETRY_MAX_MS)

    /**
     * A correction is only right for the headphone it was measured on, so the
     * curve follows the device rather than the user remembering to switch it.
     */
    private fun applyProfileFor(address: String?) {
        if (!Juicer.prefs.current.autoProfile) return
        val profile = Juicer.profiles.forDevice(address) ?: return
        if (Juicer.prefs.current.activeProfileId == profile.id) return

        Juicer.prefs.setActiveProfile(profile.id)
        Juicer.prefs.setEq(profile.eq.copy(enabled = true))
        Juicer.engine.apply(Juicer.prefs.current.eq)
    }

    /**
     * Puts the forced codec back after a reconnection.
     *
     * The link renegotiates from scratch every time the headphones come back,
     * and nothing makes a codec choice persist — so a setting the user made an
     * hour ago is simply gone. This is the whole reason the forcing feature is
     * worth having: not the one-off change, but that it survives the case.
     *
     * The delay is not padding. The A2DP broadcast arrives when the profile
     * connects, which is before the codec has been negotiated; asking too early
     * sets a preference against a link that is about to be rebuilt.
     */
    private fun reapplyCodecFor(address: String?) {
        val settings = Juicer.prefs.current
        val codec = settings.forcedCodec ?: return
        if (!settings.autoForceCodec) return
        if (Juicer.adb.state.value !is AdbState.Connected) return

        lifecycleScope.launch {
            delay(CODEC_SETTLE_MS)
            runCatching {
                Juicer.codec.apply(codec, LdacQuality.fromRaw(settings.forcedLdacRaw ?: -1L), address)
            }
        }
    }

    private fun onRouteChanged() {
        lifecycleScope.launch {
            delay(ROUTE_SETTLE_MS)
            val info = Juicer.link.refresh()
            // Re-attach unconditionally: on the ROMs that drop the effect there
            // is no signal that it happened, so the only safe move is to assume
            // it did.
            Juicer.engine.apply(Juicer.prefs.current.eq)
            if (info.route == Route.BLUETOOTH_A2DP || info.route == Route.BLUETOOTH_LE) {
                Juicer.link.refresh()
            }
            goForeground()
        }
    }

    private fun goForeground() {
        val notification = Notifications.status(
            this,
            Juicer.engine.state.value,
            Juicer.link.info.value,
            // Fed to the dynamic island: the codec is the one fact worth a
            // glance from outside the app.
            Juicer.codec.status.value?.headline(),
        )
        ServiceCompat.startForeground(
            this,
            Notifications.ID_STATUS,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
    }
}
