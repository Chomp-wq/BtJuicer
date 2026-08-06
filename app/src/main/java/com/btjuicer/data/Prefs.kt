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

    private companion object {
        const val KEY_EQ = "eq"
        const val KEY_REMIND = "remind_on_connect"
        const val KEY_CHECKLIST = "checklist_done"
        const val KEY_ADB_PAIRED = "adb_paired"
        const val KEY_POLL_CODEC = "poll_codec"
        const val KEY_ACTIVE_PROFILE = "active_profile"
        const val KEY_AUTO_PROFILE = "auto_profile"
    }
}
