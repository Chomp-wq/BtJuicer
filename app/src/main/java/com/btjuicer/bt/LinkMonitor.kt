package com.btjuicer.bt

import android.Manifest
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Route(val label: String) {
    BLUETOOTH_A2DP("Bluetooth A2DP"),
    BLUETOOTH_LE("Bluetooth LE Audio"),
    USB("DAC por USB"),
    WIRED("Cable / jack"),
    SPEAKER("Altavoz del teléfono"),
    OTHER("Otra salida"),
    UNKNOWN("Desconocida"),
}

data class LinkInfo(
    val route: Route = Route.UNKNOWN,
    val outputName: String = "",
    val btDeviceName: String = "",
    val btAddress: String = "",
    val a2dpConnected: Boolean = false,
    val playing: Boolean = false,
    /** What the phone's mixer is actually running at, in Hz. */
    val mixerSampleRateHz: Int = 0,
    val framesPerBuffer: Int = 0,
    /** Sample rates the current output reports it accepts. */
    val outputSampleRates: List<Int> = emptyList(),
    val hasBluetoothPermission: Boolean = false,
)

/**
 * Read-only view of where the audio is going, built entirely from public APIs.
 *
 * What it deliberately does *not* claim to show is the negotiated Bluetooth
 * codec. Reading that needs BLUETOOTH_PRIVILEGED, a signature permission no
 * installable app can hold, so any number shown here would be a guess. The Guide
 * screen sends you to the one place that does know.
 */
class LinkMonitor(private val context: Context) {

    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private val _info = MutableStateFlow(LinkInfo())
    val info: StateFlow<LinkInfo> = _info.asStateFlow()

    @Volatile
    private var a2dp: BluetoothA2dp? = null

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile == BluetoothProfile.A2DP) {
                a2dp = proxy as? BluetoothA2dp
                refresh()
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.A2DP) a2dp = null
        }
    }

    fun start() {
        if (hasBluetoothPermission()) {
            runCatching { adapter?.getProfileProxy(context, profileListener, BluetoothProfile.A2DP) }
        }
        refresh()
    }

    fun stop() {
        runCatching { a2dp?.let { adapter?.closeProfileProxy(BluetoothProfile.A2DP, it) } }
        a2dp = null
    }

    fun registerRouteCallback(callback: AudioDeviceCallback) {
        runCatching { audioManager?.registerAudioDeviceCallback(callback, null) }
    }

    fun unregisterRouteCallback(callback: AudioDeviceCallback) {
        runCatching { audioManager?.unregisterAudioDeviceCallback(callback) }
    }

    fun refresh(): LinkInfo {
        val output = currentOutput()
        val granted = hasBluetoothPermission()

        val connected = if (granted) {
            runCatching { a2dp?.connectedDevices.orEmpty() }.getOrDefault(emptyList())
        } else {
            emptyList()
        }
        val device = connected.firstOrNull()

        val info = LinkInfo(
            route = routeOf(output),
            outputName = runCatching { output?.productName?.toString().orEmpty() }.getOrDefault(""),
            btDeviceName = runCatching { device?.name.orEmpty() }.getOrDefault(""),
            btAddress = device?.address.orEmpty(),
            a2dpConnected = device != null,
            playing = runCatching { device?.let { a2dp?.isA2dpPlaying(it) } ?: false }.getOrDefault(false),
            mixerSampleRateHz = intProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE),
            framesPerBuffer = intProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER),
            outputSampleRates = runCatching { output?.sampleRates?.toList().orEmpty() }
                .getOrDefault(emptyList())
                .sorted(),
            hasBluetoothPermission = granted,
        )
        _info.value = info
        return info
    }

    private fun currentOutput(): AudioDeviceInfo? {
        val outputs = runCatching {
            audioManager?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.toList().orEmpty()
        }.getOrDefault(emptyList())

        // No public API names "the device the mixer is using right now", so fall
        // back to precedence: an external output always wins over the speaker.
        val ranked = listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )
        for (type in ranked) {
            outputs.firstOrNull { it.type == type }?.let { return it }
        }
        return outputs.firstOrNull()
    }

    private fun routeOf(output: AudioDeviceInfo?): Route = when (output?.type) {
        null -> Route.UNKNOWN
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> Route.BLUETOOTH_A2DP
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> Route.BLUETOOTH_LE
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> Route.USB
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> Route.WIRED
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> Route.SPEAKER
        else -> Route.OTHER
    }

    private fun intProperty(key: String): Int =
        runCatching { audioManager?.getProperty(key)?.toInt() ?: 0 }.getOrDefault(0)

    private fun hasBluetoothPermission(): Boolean =
        android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED
}
