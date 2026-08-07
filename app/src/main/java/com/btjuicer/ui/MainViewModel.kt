package com.btjuicer.ui

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.btjuicer.Juicer
import com.btjuicer.adb.AdbState
import com.btjuicer.adb.LdacQuality
import com.btjuicer.adb.WriteSupport
import com.btjuicer.audio.AutoEq
import com.btjuicer.audio.EqConfig
import com.btjuicer.audio.EqMode
import com.btjuicer.audio.Filter
import com.btjuicer.audio.Flavour
import com.btjuicer.audio.Headphone
import com.btjuicer.audio.HeadphoneMatch
import com.btjuicer.audio.MbcMode
import com.btjuicer.audio.Preset
import com.btjuicer.audio.Presets
import com.btjuicer.data.Profile
import com.btjuicer.service.JuicerService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val context: Context get() = getApplication()

    val settings = Juicer.prefs.state
    val engine = Juicer.engine.state
    val link = Juicer.link.info
    val adb = Juicer.adb.state
    val codec = Juicer.codec.status
    val codecError = Juicer.codec.error
    val codecWrite = Juicer.codec.writeSupport
    val codecBusy = Juicer.codec.busy
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
        launchSafely { Juicer.link.refresh() }
    }

    /**
     * A coroutine that cannot take the app down with it.
     *
     * Everything launched from here reaches across the ADB socket, into a vendor
     * dump, or into a shell process — three places where a surprise is the
     * normal case rather than the exceptional one. An uncaught throwable in
     * `viewModelScope` is an app crash, and losing the whole app because a dump
     * came back in an unexpected shape is never the right trade: the failure
     * belongs in the snackbar.
     */
    private fun launchSafely(block: suspend () -> Unit): Job =
        viewModelScope.launch {
            runCatching { block() }.onFailure { failure ->
                // Cancellation is how coroutines shut down, not a failure.
                if (failure is CancellationException) throw failure
                Log.w("BTJuicer", "background work failed", failure)
                _messages.tryEmit(failure.message ?: failure.javaClass.simpleName)
            }
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

    // ------------------------------------------------------------- audífonos

    private val _headphoneQuery = MutableStateFlow("")
    val headphoneQuery: StateFlow<String> = _headphoneQuery

    private val _headphoneResults = MutableStateFlow<List<HeadphoneMatch>>(emptyList())
    val headphoneResults: StateFlow<List<HeadphoneMatch>> = _headphoneResults

    private val _searching = MutableStateFlow(false)
    val searching: StateFlow<Boolean> = _searching

    /** Kept so switching flavour or source re-applies without searching again. */
    private val _appliedHeadphone = MutableStateFlow<Headphone?>(null)
    val appliedHeadphone: StateFlow<Headphone?> = _appliedHeadphone

    /** The other people who measured the same model, offered as alternatives. */
    private val _alternatives = MutableStateFlow<List<Headphone>>(emptyList())
    val alternatives: StateFlow<List<Headphone>> = _alternatives

    private val _flavour = MutableStateFlow(Flavour.REFERENCE)
    val flavour: StateFlow<Flavour> = _flavour

    private var searchJob: Job? = null

    /**
     * Debounced: a scan of the whole database per keystroke would be wasted work
     * on results nobody reads, and the list flickering under the user's thumb is
     * worse than a quarter-second of stillness.
     */
    fun searchHeadphones(query: String) {
        _headphoneQuery.value = query
        searchJob?.cancel()
        if (query.isBlank()) {
            _headphoneResults.value = emptyList()
            _searching.value = false
            return
        }
        _searching.value = true
        searchJob = launchSafely {
            delay(250)
            _headphoneResults.value = Juicer.headphones.search(query)
            _searching.value = false
        }
    }

    fun applyMatch(match: HeadphoneMatch) {
        _alternatives.value = match.measurements
        applyHeadphone(match.preferred)
    }

    fun applyHeadphone(headphone: Headphone) {
        _appliedHeadphone.value = headphone
        commitHeadphone(headphone, _flavour.value)
        _messages.tryEmit("${headphone.name} — medido por ${headphone.source}")
    }

    fun setFlavour(flavour: Flavour) {
        _flavour.value = flavour
        val headphone = _appliedHeadphone.value ?: return
        commitHeadphone(headphone, flavour)
    }

    private fun commitHeadphone(headphone: Headphone, flavour: Flavour) {
        val next = Juicer.prefs.current.eq.withFilters(
            headphone.filters + flavour.extra,
            "${headphone.name} · ${headphone.label}",
        )
        // AutoEq ships a preamp computed for its own curve; a flavour adds boost
        // on top of it. Taking whichever is lower means neither can clip.
        val preamp = minOf(headphone.preampDb, next.suggestedPreamp())
        commit(next.copy(preampDb = preamp.coerceIn(-20f, 0f), enabled = true))
        JuicerService.start(context)
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
        launchSafely {
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
        launchSafely {
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

    /** For a socket that answers nothing: drop it and dial again. */
    fun reconnectAdb() {
        launchSafely {
            Juicer.codec.clear()
            Juicer.adb.reconnect().fold(
                onSuccess = { refreshCodec() },
                onFailure = { _messages.tryEmit(it.message ?: "No se pudo reconectar") },
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
        launchSafely {
            if (Juicer.adb.state.value !is AdbState.Connected) {
                _messages.tryEmit("Sin conexión ADB")
                return@launchSafely
            }
            Juicer.codec.refresh()
        }
    }

    fun setPollCodec(enabled: Boolean) {
        Juicer.prefs.setPollCodec(enabled)
        if (enabled) JuicerService.start(context)
    }

    // ------------------------------------------------------- forzar el códec

    fun setForcedCodec(codec: Int?, quality: LdacQuality?) {
        Juicer.prefs.setForcedCodec(codec, quality?.raw)
    }

    fun setAutoForceCodec(enabled: Boolean) {
        Juicer.prefs.setAutoForceCodec(enabled)
        // Re-applying on reconnection is the service's job, so turning this on
        // without the service running would be a switch that does nothing.
        if (enabled) JuicerService.start(context)
    }

    /**
     * Sends the chosen codec to the phone and reports what actually stuck.
     *
     * The chosen values are stored first: if the phone accepts them, the service
     * needs them to put the codec back after the next reconnection, and if it
     * refuses, having the choice remembered is what lets the user retry.
     */
    fun applyCodec(codec: Int, quality: LdacQuality?) {
        launchSafely {
            if (Juicer.adb.state.value !is AdbState.Connected) {
                _messages.tryEmit("Conecta primero por ADB")
                return@launchSafely
            }
            Juicer.prefs.setForcedCodec(codec, quality?.raw)
            val address = Juicer.link.info.value.btAddress.takeIf { it.isNotEmpty() }
            Juicer.codec.apply(codec, quality, address).fold(
                onSuccess = { _messages.tryEmit(it) },
                onFailure = { _messages.tryEmit(it.message ?: "No se pudo fijar el códec") },
            )
        }
    }

    fun probeCodecWrite() {
        launchSafely {
            if (Juicer.adb.state.value !is AdbState.Connected) {
                _messages.tryEmit("Conecta primero por ADB")
                return@launchSafely
            }
            val address = Juicer.link.info.value.btAddress.takeIf { it.isNotEmpty() }
            when (val support = Juicer.codec.probeWrite(address)) {
                WriteSupport.Yes -> _messages.tryEmit("Tu teléfono sí deja fijar el códec")
                is WriteSupport.No -> _messages.tryEmit(support.reason)
                WriteSupport.Unknown -> Unit
            }
        }
    }

    fun notify(message: String) {
        _messages.tryEmit(message)
    }

    private fun commit(config: EqConfig) {
        Juicer.prefs.setEq(config)
        Juicer.engine.apply(config)
    }
}
