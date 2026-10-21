package com.secretsavior.data

import android.content.Context
import com.secretsavior.guard.Status
import com.secretsavior.vpn.DnsFilter

/**
 * Lo poco que la app recuerda. Todo es de ida: se puede añadir un dominio, pero
 * no quitarlo; se puede bloquear, pero no desbloquear.
 */
object Store {

    private fun prefs(c: Context) =
        c.applicationContext.getSharedPreferences("savior", Context.MODE_PRIVATE)

    /** Cuándo se activó el bloqueo (ms desde 1970), o 0 si aún no. */
    fun lockedAt(c: Context): Long = prefs(c).getLong("locked_at", 0L)

    /**
     * Bloqueada = el usuario pulsó "activar", o el sistema aún tiene a la app
     * como administrador. Lo segundo importa: si alguien borra los datos de la
     * app, el administrador sigue ahí y el bloqueo no se evapora con ellos.
     */
    fun isLocked(c: Context): Boolean {
        if (lockedAt(c) > 0) return true
        if (Status.isAdminActive(c)) {
            lock(c)
            return true
        }
        return false
    }

    fun lock(c: Context) {
        if (lockedAt(c) == 0L) prefs(c).edit().putLong("locked_at", System.currentTimeMillis()).apply()
    }

    fun daysLocked(c: Context): Long {
        val at = lockedAt(c)
        return if (at == 0L) 0 else (System.currentTimeMillis() - at) / DAY_MS
    }

    fun blockedCount(c: Context): Int = prefs(c).getInt("blocked", 0)

    @Synchronized
    fun countBlock(c: Context) {
        val p = prefs(c)
        p.edit().putInt("blocked", p.getInt("blocked", 0) + 1).apply()
    }

    fun extraDomains(c: Context): Set<String> =
        prefs(c).getStringSet("extra", emptySet()).orEmpty().toSet()

    /** Devuelve false si lo escrito no es un dominio. */
    @Synchronized
    fun addDomain(c: Context, input: String): Boolean {
        val d = DnsFilter.normalize(input) ?: return false
        val all = extraDomains(c) + d
        prefs(c).edit().putStringSet("extra", all).apply()
        DnsFilter.extra = all
        return true
    }

    /**
     * Ventana corta en la que el guardián deja pasar las pantallas de batería y
     * autoinicio, que nombran a la app. Sólo se abre desde dentro de la app y nunca
     * deja pasar las que ofrecen desinstalar, parar u ocultar (ver GuardService).
     */
    fun openGrace(c: Context) {
        prefs(c).edit().putLong("grace_until", System.currentTimeMillis() + GRACE_MS).apply()
    }

    fun inGrace(c: Context): Boolean = System.currentTimeMillis() < prefs(c).getLong("grace_until", 0L)

    /** Las razones propias, para leerlas justo cuando más falta hacen. */
    fun reason(c: Context): String = prefs(c).getString("reason", "").orEmpty()

    fun setReason(c: Context, text: String) {
        prefs(c).edit().putString("reason", text.take(600)).apply()
    }

    private const val GRACE_MS = 120_000L
    private const val DAY_MS = 24L * 60 * 60 * 1000
}
