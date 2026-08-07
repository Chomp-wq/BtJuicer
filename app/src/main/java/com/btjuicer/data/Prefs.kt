package com.btjuicer.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.btjuicer.audio.EqConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

data class Settings(
    val eq: EqConfig = EqConfig(),
    /** Notify when a Bluetooth output connects, so the LDAC check is one tap away. */
    val remindOnConnect: Boolean = true,
    /** Set once the user says they have gone through the LDAC checklist. */
    val checklistDone: Boolean = false,
    /** The ADB daemon has trusted our key at least once. */
    val adbPaired: Boolean = false,
    /** Keep reading the codec in the background while ADB is connected. */
    val pollCodec: Boolean = true,
    /** Profile currently loaded, so the UI can show which one is live. */
    val activeProfileId: String? = null,
    /** Swap curves automatically when a bound headphone connects. */
    val autoProfile: Boolean = true,
    /** Codec to force, as a BluetoothCodecConfig type. Null means leave it alone. */
    val forcedCodec: Int? = null,
    /** LDAC tier to ask for, as its raw codecSpecific1 value. */
    val forcedLdacRaw: Long? = null,
    /**
     * Re-apply the forced codec whenever a headphone connects.
     *
     * The Bluetooth link renegotiates the codec on every reconnection and there
     * is no API that makes a choice stick, so without this the setting undoes
     * itself the first time the headphones go back in the case.
     */
    val autoForceCodec: Boolean = false,
)

class Prefs(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("btjuicer", Context.MODE_PRIVATE)

    private val _state = MutableStateFlow(read())
    val state: StateFlow<Settings> = _state.asStateFlow()

    val current: Settings get() = _state.value

    private fun read(): Settings = Settings(
        eq = prefs.getString(KEY_EQ, null)
            ?.let { runCatching { EqConfig.fromJson(JSONObject(it)) }.getOrNull() }
            ?: EqConfig(),
        remindOnConnect = prefs.getBoolean(KEY_REMIND, true),
        checklistDone = prefs.getBoolean(KEY_CHECKLIST, false),
        adbPaired = prefs.getBoolean(KEY_ADB_PAIRED, false),
        pollCodec = prefs.getBoolean(KEY_POLL_CODEC, true),
        activeProfileId = prefs.getString(KEY_ACTIVE_PROFILE, null),
        autoProfile = prefs.getBoolean(KEY_AUTO_PROFILE, true),
        forcedCodec = prefs.getInt(KEY_FORCED_CODEC, NONE).takeIf { it != NONE },
        forcedLdacRaw = prefs.getLong(KEY_FORCED_LDAC, NONE.toLong()).takeIf { it != NONE.toLong() },
        autoForceCodec = prefs.getBoolean(KEY_AUTO_FORCE, false),
    )

    private fun update(block: Settings.() -> Settings) {
        val next = _state.value.block()
        prefs.edit {
            putString(KEY_EQ, next.eq.toJson().toString())
            putBoolean(KEY_REMIND, next.remindOnConnect)
            putBoolean(KEY_CHECKLIST, next.checklistDone)
            putBoolean(KEY_ADB_PAIRED, next.adbPaired)
            putBoolean(KEY_POLL_CODEC, next.pollCodec)
            putString(KEY_ACTIVE_PROFILE, next.activeProfileId)
            putBoolean(KEY_AUTO_PROFILE, next.autoProfile)
            putInt(KEY_FORCED_CODEC, next.forcedCodec ?: NONE)
            putLong(KEY_FORCED_LDAC, next.forcedLdacRaw ?: NONE.toLong())
            putBoolean(KEY_AUTO_FORCE, next.autoForceCodec)
        }
        _state.value = next
    }

    fun setEq(eq: EqConfig) = update { copy(eq = eq) }

    fun setRemindOnConnect(enabled: Boolean) = update { copy(remindOnConnect = enabled) }

    fun setChecklistDone(done: Boolean) = update { copy(checklistDone = done) }

    fun setAdbPaired(paired: Boolean) = update { copy(adbPaired = paired) }

    fun setPollCodec(enabled: Boolean) = update { copy(pollCodec = enabled) }

    fun setActiveProfile(id: String?) = update { copy(activeProfileId = id) }

    fun setAutoProfile(enabled: Boolean) = update { copy(autoProfile = enabled) }

    fun setForcedCodec(codec: Int?, ldacRaw: Long?) =
        update { copy(forcedCodec = codec, forcedLdacRaw = ldacRaw) }

    fun setAutoForceCodec(enabled: Boolean) = update { copy(autoForceCodec = enabled) }

    private companion object {
        /** SharedPreferences has no "absent int", so one value stands in for null. */
        const val NONE = -1

        const val KEY_EQ = "eq"
        const val KEY_REMIND = "remind_on_connect"
        const val KEY_CHECKLIST = "checklist_done"
        const val KEY_ADB_PAIRED = "adb_paired"
        const val KEY_POLL_CODEC = "poll_codec"
        const val KEY_ACTIVE_PROFILE = "active_profile"
        const val KEY_AUTO_PROFILE = "auto_profile"
        const val KEY_FORCED_CODEC = "forced_codec"
        const val KEY_FORCED_LDAC = "forced_ldac"
        const val KEY_AUTO_FORCE = "auto_force_codec"
    }
}
