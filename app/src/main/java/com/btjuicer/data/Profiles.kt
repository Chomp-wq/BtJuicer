package com.btjuicer.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.btjuicer.audio.EqConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * A saved curve, optionally tied to one pair of headphones.
 *
 * The point of the binding is that a correction is only ever right for the
 * headphone it was measured on. Carrying an AutoEq curve for one model over to
 * another is worse than no EQ at all, so profiles bound to a MAC address get
 * applied when that device connects and put away when it leaves.
 */
data class Profile(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** Bluetooth address this profile belongs to, or null for a manual profile. */
    val deviceAddress: String? = null,
    val deviceName: String = "",
    val eq: EqConfig,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("address", deviceAddress ?: JSONObject.NULL)
        put("deviceName", deviceName)
        put("eq", eq.toJson())
    }

    companion object {
        fun fromJson(json: JSONObject): Profile? {
            val eq = json.optJSONObject("eq") ?: return null
            return Profile(
                id = json.optString("id").ifEmpty { UUID.randomUUID().toString() },
                name = json.optString("name").ifEmpty { "Sin nombre" },
                deviceAddress = json.optString("address").takeIf {
                    it.isNotEmpty() && it != "null"
                },
                deviceName = json.optString("deviceName"),
                eq = EqConfig.fromJson(eq),
            )
        }
    }
}

class ProfileStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("btjuicer-profiles", Context.MODE_PRIVATE)

    private val _profiles = MutableStateFlow(read())
    val profiles: StateFlow<List<Profile>> = _profiles.asStateFlow()

    private fun read(): List<Profile> = runCatching {
        val raw = prefs.getString(KEY, null) ?: return@runCatching emptyList()
        val array = JSONArray(raw)
        buildList {
            for (i in 0 until array.length()) {
                array.optJSONObject(i)?.let(Profile::fromJson)?.let(::add)
            }
        }
    }.getOrDefault(emptyList())

    private fun write(next: List<Profile>) {
        val array = JSONArray().also { arr -> next.forEach { arr.put(it.toJson()) } }
        prefs.edit { putString(KEY, array.toString()) }
        _profiles.value = next
    }

    /** Inserts or replaces by id. */
    fun save(profile: Profile) {
        val next = _profiles.value.filterNot { it.id == profile.id } + profile
        write(next.sortedBy { it.name.lowercase() })
    }

    fun delete(id: String) = write(_profiles.value.filterNot { it.id == id })

    fun byId(id: String?): Profile? = id?.let { key -> _profiles.value.firstOrNull { it.id == key } }

    /** The profile bound to [address], if any. */
    fun forDevice(address: String?): Profile? {
        if (address.isNullOrEmpty()) return null
        return _profiles.value.firstOrNull { it.deviceAddress.equals(address, ignoreCase = true) }
    }

    private companion object {
        const val KEY = "profiles"
    }
}
