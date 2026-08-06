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
     * Only polls while ADB is actually connected; it never dials on its own.
     * Reconnecting behind the user's back would mean silently reopening a
     * debugging channel, which is theirs to decide.
     */
    private fun startCodecPolling() {
        if (codecJob?.isActive == true) return
        codecJob = lifecycleScope.launch {
            while (isActive) {
                if (Juicer.prefs.current.pollCodec && Juicer.adb.state.value is AdbState.Connected) {
                    runCatching { Juicer.codec.refresh() }
                }
                delay(CODEC_POLL_MS)
            }
        }
    }

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
        )
        ServiceCompat.startForeground(
            this,
            Notifications.ID_STATUS,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
    }
}
