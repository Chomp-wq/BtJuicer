package com.secretsavior.guard

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.data.Store
import com.secretsavior.vpn.DnsFilter
import com.secretsavior.vpn.SaviorVpnService

/** Vuelve a levantar lo que se haya caído. Nunca apaga nada. */
object Watchdog {

    private const val TAG = "SecretSavior"

    /** Reinicia el filtro si estaba bloqueado y no corre. Devuelve false si hace falta el usuario. */
    fun ensure(c: Context): Boolean {
        if (!Store.isLocked(c)) return true
        DnsFilter.extra = Store.extraDomains(c)
        if (SaviorVpnService.running) return true
        if (VpnService.prepare(c) != null) return false // otra VPN le quitó el permiso
        return try {
            c.startService(Intent(c, SaviorVpnService::class.java))
            true
        } catch (e: Exception) {
            // Android 12+ puede negar arrancar servicios desde segundo plano.
            Log.w(TAG, "no se pudo arrancar el filtro", e)
            false
        }
    }

    /** Trae la app al frente para que el usuario repare lo que falta. */
    fun nag(c: Context) {
        try {
            c.startActivity(
                Intent(c, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            )
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo abrir la app", e)
        }
    }
}
