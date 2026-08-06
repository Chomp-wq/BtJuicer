package com.btjuicer.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.btjuicer.Juicer
import com.btjuicer.adb.AdbState
import com.btjuicer.audio.AutoEq
import com.btjuicer.audio.EqConfig
import com.btjuicer.audio.EqMode
import com.btjuicer.audio.Filter
import com.btjuicer.audio.MbcMode
import com.btjuicer.audio.Preset
import com.btjuicer.audio.Presets
import com.btjuicer.data.Profile
import com.btjuicer.service.JuicerService
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val context: Context get() = getApplication()

    val settings = Juicer.prefs.state
    val engine = Juicer.engine.state
    val link = Juicer.link.info
    val adb = Juicer.adb.state
    val codec = Juicer.codec.status
    val codecError = Juicer.codec.error
    val profiles = Juicer.profiles.profiles

    private val _messages = MutableSharedFlow<String>(
        replay = 0,
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val messages: SharedFlow<String> = _messages

    init {
        Juicer.link.start()
        refreshLink()
    }

    fun refreshLink() {
        viewModelScope.launch { Juicer.link.refresh() }
    }

    /**
     * The foreground service is what keeps the effect attached across route
     * changes, so it is tied to the switch rather than offered separately —
     * one control, one outcome.
     */
    fun setEqEnabled(enabled: Boolean) {
        commit(Juicer.prefs.current.eq.copy(enabled = enabled))
        if (enabled) JuicerService.start(context) else JuicerService.stop(context)
    }

    fun setBand(index: Int, targetDb: Float) {
        commit(Juicer.prefs.current.eq.withBand(index, targetDb))
    }

    fun setMode(mode: EqMode) {
        val eq = Juicer.prefs.current.eq
        // Switching to parametric carries the simple curve across rather than
        // dropping it, so the user starts from what they were already hearing.
        val next = if (mode == EqMode.PARAMETRIC && eq.filters.isEmpty()) {
            eq.copy(mode = mode, filters = eq.activeFilters())
        } else {
            eq.copy(mode = mode)
        }
        commit(next)
    }

    fun setMbc(mode: MbcMode) {
        commit(Juicer.prefs.current.eq.copy(mbc = mode))
    }

    // ------------------------------------------------------------- filtros

    fun addFilter() {
        val eq = Juicer.prefs.current.eq
        val next = eq.filters + Filter()
        commit(eq.withFilters(next, eq.sourceLabel))
    }

    fun updateFilter(index: Int, filter: Filter) {
        val eq = Juicer.prefs.current.eq
        val next = eq.filters.toMutableList()
        if (index !in next.indices) return
        next[index] = filter
        commit(eq.withFilters(next, eq.sourceLabel))
    }

    fun removeFilter(index: Int) {
        val eq = Juicer.prefs.current.eq
        val next = eq.filters.toMutableList()
        if (index !in next.indices) return
        next.removeAt(index)
        commit(eq.withFilters(next, eq.sourceLabel))
    }

    /**
     * Imports an AutoEq profile. Applies the file's own preamp when it carries
     * one — AutoEq computes it for exactly this reason — and otherwise derives
     * the value from the curve.
     */
    fun importAutoEq(text: String) {
        AutoEq.parse(text).fold(
            onSuccess = { imported ->
                val eq = Juicer.prefs.current.eq
                    .withFilters(imported.filters, imported.sourceLabel)
                val preamp = imported.preampDb ?: eq.suggestedPreamp()
                commit(eq.copy(preampDb = preamp.coerceIn(-20f, 6f), enabled = true))
                _messages.tryEmit("Importado: ${imported.sourceLabel}")
            },
            onFailure = { _messages.tryEmit(it.message ?: "No se pudo leer el perfil") },
        )
    }

    // ------------------------------------------------------------- perfiles

    fun saveProfile(name: String, bindToConnectedDevice: Boolean) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) {
            _messages.tryEmit("Ponle un nombre al perfil")
            return
        }
        val link = Juicer.link.info.value
        val profile = Profile(
            name = trimmed,
            deviceAddress = if (bindToConnectedDevice) link.btAddress.takeIf { it.isNotEmpty() } else null,
            deviceName = if (bindToConnectedDevice) link.btDeviceName else "",
            eq = Juicer.prefs.current.eq,
        )
        Juicer.profiles.save(profile)
        Juicer.prefs.setActiveProfile(profile.id)
        _messages.tryEmit(
            if (profile.deviceAddress != null) {
                "Guardado y asociado a ${profile.deviceName.ifEmpty { "estos audífonos" }}"
            } else {
                "Perfil guardado"
            },
        )
    }

    fun applyProfile(id: String) {
        val profile = Juicer.profiles.byId(id) ?: return
        Juicer.prefs.setActiveProfile(id)
        commit(profile.eq.copy(enabled = true))
        JuicerService.start(context)
        _messages.tryEmit("Perfil «${profile.name}» aplicado")
    }

    fun deleteProfile(id: String) {
        Juicer.profiles.delete(id)
        if (Juicer.prefs.current.activeProfileId == id) Juicer.prefs.setActiveProfile(null)
    }

    fun setAutoProfile(enabled: Boolean) = Juicer.prefs.setAutoProfile(enabled)

    fun setPreamp(db: Float) {
        commit(Juicer.prefs.current.eq.copy(preampDb = db))
    }

    fun setLimiter(enabled: Boolean) {
        commit(Juicer.prefs.current.eq.copy(limiterEnabled = enabled))
        if (!enabled) {
            _messages.tryEmit(
                "Sin limitador, subir bandas puede saturar. Compensa con la ganancia previa.",
            )
        }
    }

    fun applyPreset(preset: Preset) {
        val current = Juicer.prefs.current.eq
        val next = current.copy(
            mode = EqMode.SIMPLE,
            bandsDb = preset.bandsDb,
            presetName = preset.label,
            sourceLabel = "",
        )
        commit(next.copy(preampDb = next.suggestedPreamp()))
    }

    /** Drops the preamp just enough to offset the biggest boost. */
    fun autoPreamp() {
        val eq = Juicer.prefs.current.eq
        commit(eq.copy(preampDb = eq.suggestedPreamp()))
        _messages.tryEmit("Ganancia previa ajustada para no saturar")
    }

    fun resetFlat() = applyPreset(Presets.FLAT)

    fun setRemindOnConnect(enabled: Boolean) = Juicer.prefs.setRemindOnConnect(enabled)

    fun setChecklistDone(done: Boolean) = Juicer.prefs.setChecklistDone(done)

    // ------------------------------------------------------------------ adb

    /**
     * Pairing is a one-time ritual: the daemon remembers the key, so later
     * reconnections need nothing but the port. Hence storing the flag.
     */
    fun pairAdb(code: String) {
        val trimmed = code.trim()
        if (trimmed.length < 6) {
            _messages.tryEmit("El código de emparejamiento tiene 6 dígitos")
            return
        }
        viewModelScope.launch {
            Juicer.adb.pair(trimmed).fold(
                onSuccess = {
                    Juicer.prefs.setAdbPaired(true)
                    _messages.tryEmit("Emparejado. Conectando…")
                    connectAdb()
                },
                onFailure = { _messages.tryEmit(it.message ?: "El emparejamiento falló") },
            )
        }
    }

    fun connectAdb() {
        viewModelScope.launch {
            Juicer.adb.connect().fold(
                onSuccess = {
                    refreshCodec()
                    if (Juicer.prefs.current.eq.enabled || Juicer.prefs.current.pollCodec) {
                        JuicerService.start(context)
                    }
                },
                onFailure = { _messages.tryEmit(it.message ?: "No se pudo conectar") },
            )
        }
    }

    fun disconnectAdb() {
        Juicer.adb.disconnect()
        Juicer.codec.clear()
    }

    fun forgetAdb() {
        Juicer.adb.forget()
        Juicer.codec.clear()
        Juicer.prefs.setAdbPaired(false)
        _messages.tryEmit("Identidad borrada. Habrá que emparejar de nuevo.")
    }

    fun refreshCodec() {
        viewModelScope.launch {
            if (Juicer.adb.state.value !is AdbState.Connected) {
                _messages.tryEmit("Sin conexión ADB")
                return@launch
            }
            Juicer.codec.refresh()
        }
    }

    fun setPollCodec(enabled: Boolean) {
        Juicer.prefs.setPollCodec(enabled)
        if (enabled) JuicerService.start(context)
    }

    fun notify(message: String) {
        _messages.tryEmit(message)
    }

    private fun commit(config: EqConfig) {
        Juicer.prefs.setEq(config)
        Juicer.engine.apply(config)
    }
}
