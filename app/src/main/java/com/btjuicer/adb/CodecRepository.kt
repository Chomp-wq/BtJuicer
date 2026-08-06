package com.btjuicer.adb

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Live view of the negotiated Bluetooth codec, read over the ADB shell.
 *
 * Read-only by design. There is no shell command that sets the codec, so the app
 * shows you what the link is doing and the Guide tells you where to change it.
 */
class CodecRepository(private val adb: AdbLink) {

    private val _status = MutableStateFlow<CodecStatus?>(null)
    val status: StateFlow<CodecStatus?> = _status.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    suspend fun refresh(): CodecStatus? {
        if (adb.state.value !is AdbState.Connected) return null

        val output = adb.shell("dumpsys bluetooth_manager").getOrElse {
            _error.value = it.message
            return null
        }

        val parsed = DumpsysCodec.parse(output)
        if (parsed == null) {
            // An empty dump is the normal state with nothing connected; a dump
            // that exists but has no codec block means something changed shape.
            _error.value = if (output.isBlank()) {
                "El volcado vino vacío. ¿Sigue activa la depuración inalámbrica?"
            } else {
                "No se encontró la configuración del códec en el volcado. Conecta unos " +
                    "audífonos y pon música."
            }
            return null
        }

        _error.value = null
        _status.value = parsed
        return parsed
    }

    fun clear() {
        _status.value = null
        _error.value = null
    }
}
