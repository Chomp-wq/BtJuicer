package com.secretsavior.guard

import android.content.ComponentName
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.secretsavior.data.Store
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Autocuración: con WRITE_SECURE_SETTINGS (concedido una vez por ADB) la app deshace sola los
 * cambios que la apagarían. Sin el permiso no hace nada. Sólo escribe si el valor difiere,
 * para no entrar en bucle con un observador que se dispara con su propia escritura.
 */
object SelfHeal {

    private const val TAG = "SecretSavior"
    private const val ADB_WIFI = "adb_wifi_enabled" // no hay constante pública

    private val watching = AtomicBoolean(false)

    fun heal(c: Context) {
        try {
            if (!Status.hasSecureSettings(c) || !Store.isLocked(c)) return
            val app = c.applicationContext
            healAccessibility(app)
            healPrivateDns(app)
            if (Store.devOptionsBlocked(app)) healDevOptions(app)
        } catch (e: Exception) {
            Log.w(TAG, "autocuración", e)
        }
    }

    private fun healAccessibility(c: Context) {
        step("accesibilidad") {
            val me = ComponentName(c, GuardService::class.java).flattenToString()
            val cur = Settings.Secure.getString(c.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            val merged = A11yList.merge(cur, me)
            if (merged != cur.orEmpty()) {
                Settings.Secure.putString(c.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, merged)
            }
            if (Settings.Secure.getInt(c.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0) != 1) {
                Settings.Secure.putInt(c.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            }
        }
    }

    private fun healPrivateDns(c: Context) {
        step("dns privado") {
            // «hostname» cifra hacia un proveedor y se salta el filtro; «opportunistic» no.
            if (Status.isPrivateDnsStrict(c)) {
                Settings.Global.putString(c.contentResolver, "private_dns_mode", "opportunistic")
            }
        }
    }

    private fun healDevOptions(c: Context) {
        step("opciones de desarrollador") {
            putGlobalInt(c, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0)
            putGlobalInt(c, Settings.Global.ADB_ENABLED, 0)
            putGlobalInt(c, ADB_WIFI, 0)
        }
    }

    private fun putGlobalInt(c: Context, key: String, v: Int) {
        if (Settings.Global.getInt(c.contentResolver, key, 0) != v) Settings.Global.putInt(c.contentResolver, key, v)
    }

    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.w(TAG, "autocuración: $name", e)
        }
    }

    /**
     * Observadores (una vez por proceso, hilo principal): mientras el proceso viva, cualquier
     * cambio se deshace al instante, sin esperar a la ronda del watchdog.
     */
    fun watch(c: Context) {
        if (watching.get() || !Status.hasSecureSettings(c)) return
        if (!watching.compareAndSet(false, true)) return
        val app = c.applicationContext
        try {
            val obs = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) = heal(app)
            }
            val uris: List<Uri> = listOf(
                Settings.Secure.getUriFor(Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES),
                Settings.Secure.getUriFor(Settings.Secure.ACCESSIBILITY_ENABLED),
                Settings.Global.getUriFor("private_dns_mode"),
                Settings.Global.getUriFor(Settings.Global.DEVELOPMENT_SETTINGS_ENABLED),
                Settings.Global.getUriFor(Settings.Global.ADB_ENABLED),
                Settings.Global.getUriFor(ADB_WIFI),
            )
            for (u in uris) app.contentResolver.registerContentObserver(u, false, obs)
        } catch (e: Exception) {
            watching.set(false)
            Log.w(TAG, "no se pudo vigilar los ajustes", e)
        }
    }
}
