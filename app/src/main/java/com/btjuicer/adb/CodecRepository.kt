package com.btjuicer.adb

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Whether this phone will let BT Juicer write the codec, once actually tried. */
sealed interface WriteSupport {
    data object Unknown : WriteSupport

    data object Yes : WriteSupport

    /** Tried and refused; [reason] is what the phone said. */
    data class No(val reason: String) : WriteSupport
}

/**
 * The negotiated Bluetooth codec: reading it, and setting it.
 *
 * Two paths, on purpose. Reading goes through `dumpsys`, which is cheap enough to
 * poll every few seconds and cannot fail in any interesting way. Writing goes
 * through the privileged helper, which is heavier — it starts a process — and is
 * only run when the user asks for it or a headphone reconnects.
 *
 * Whether writing works at all is never assumed. [WriteSupport] starts
 * [WriteSupport.Unknown] and only moves once a real attempt has come back.
 */
class CodecRepository(private val adb: AdbLink, context: Context) {

    private val control = CodecControl(adb, context)

    private val _status = MutableStateFlow<CodecStatus?>(null)
    val status: StateFlow<CodecStatus?> = _status.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _writeSupport = MutableStateFlow<WriteSupport>(WriteSupport.Unknown)
    val writeSupport: StateFlow<WriteSupport> = _writeSupport.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

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

    /**
     * Asks the phone to use [codecType], and reports what it actually did.
     *
     * The helper waits for the link to renegotiate and reads the codec back, so
     * the message returned here reflects the outcome rather than the request —
     * a sink that refuses LDAC leaves you on SBC, and saying "applied" then
     * would be a lie.
     */
    suspend fun apply(
        codecType: Int,
        quality: LdacQuality?,
        address: String?,
    ): Result<String> {
        _busy.value = true
        try {
            val report = control.apply(address, codecType, quality)
                .getOrElse { return Result.failure(it) }

            report.error?.let { message ->
                if (!report.privileged && report.fields.containsKey("privileged")) {
                    _writeSupport.value = WriteSupport.No(message)
                }
                return Result.failure(IllegalStateException(message))
            }
            _writeSupport.value = WriteSupport.Yes

            val applied = report.status("applied") ?: report.status("current")
            if (applied != null) _status.value = applied

            val wanted = CodecType.label(codecType)
            return Result.success(
                when {
                    applied == null -> "Aplicado. Vuelve a leer para confirmarlo."
                    applied.codecType != codecType ->
                        "El teléfono no aceptó $wanted; sigue en ${applied.headline()}"
                    else -> "Ahora: ${applied.headline()}${
                        applied.subline().takeIf(String::isNotEmpty)?.let { " · $it" }.orEmpty()
                    }"
                },
            )
        } finally {
            _busy.value = false
        }
    }

    /** Runs the helper without changing anything, to find out whether it can. */
    suspend fun probeWrite(address: String?): WriteSupport {
        _busy.value = true
        try {
            val report = control.probe(address).getOrElse {
                val support = WriteSupport.No(it.message ?: "El ayudante no respondió")
                _writeSupport.value = support
                return support
            }
            val support = when {
                report.privileged -> WriteSupport.Yes
                else -> WriteSupport.No(report.error ?: "El usuario shell no tiene el permiso")
            }
            _writeSupport.value = support
            report.status("current")?.let { _status.value = it }
            return support
        } finally {
            _busy.value = false
        }
    }

    fun clear() {
        _status.value = null
        _error.value = null
        _writeSupport.value = WriteSupport.Unknown
    }
}
