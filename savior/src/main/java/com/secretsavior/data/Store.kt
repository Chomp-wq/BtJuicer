package com.secretsavior.data

import android.content.Context
import android.os.SystemClock
import com.secretsavior.guard.Status
import com.secretsavior.vpn.DnsFilter
import java.util.concurrent.atomic.AtomicInteger

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
        if (lockedCache) return true // es de ida: una vez bloqueada no vuelve atrás
        if (lockedAt(c) > 0) {
            lockedCache = true
            return true
        }
        if (Status.isAdminActive(c)) {
            lock(c)
            return true
        }
        return false
    }

    fun lock(c: Context) {
        if (lockedAt(c) == 0L) prefs(c).edit().putLong("locked_at", System.currentTimeMillis()).apply()
        lockedCache = true
    }

    /** Se consulta en cada evento de accesibilidad: mejor una variable que las preferencias. */
    @Volatile
    private var lockedCache = false

    fun daysLocked(c: Context): Long {
        val at = lockedAt(c)
        return if (at == 0L) 0 else (System.currentTimeMillis() - at) / DAY_MS
    }

    fun blockedCount(c: Context): Int = prefs(c).getInt("blocked", 0) + unsaved.get()

    /**
     * Se cuenta en memoria y se guarda como mucho cada [FLUSH_MS]: una página puede tener
     * muchos dominios bloqueados y cada guardado reescribe el archivo de preferencias.
     */
    fun countBlock(c: Context) {
        unsaved.incrementAndGet()
        val now = SystemClock.elapsedRealtime()
        if (now - lastFlush >= FLUSH_MS) flush(c, now)
    }

    @Synchronized
    private fun flush(c: Context, now: Long) {
        lastFlush = now
        val n = unsaved.getAndSet(0)
        if (n == 0) return
        val p = prefs(c)
        p.edit().putInt("blocked", p.getInt("blocked", 0) + n).apply()
    }

    private val unsaved = AtomicInteger()

    @Volatile
    private var lastFlush = Long.MIN_VALUE / 2

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

    /** Se ha visto el autoinicio de la app encendido: desde entonces no se deja apagar. */
    fun autostartSeen(c: Context): Boolean = prefs(c).getBoolean("autostart_seen", false)

    fun setAutostartSeen(c: Context) {
        if (!autostartSeen(c)) prefs(c).edit().putBoolean("autostart_seen", true).apply()
    }

    /** Las razones propias, para leerlas justo cuando más falta hacen. */
    fun reason(c: Context): String = prefs(c).getString("reason", "").orEmpty()

    fun setReason(c: Context, text: String) {
        prefs(c).edit().putString("reason", text.take(600)).apply()
    }

    private const val FLUSH_MS = 30_000L
    private const val GRACE_MS = 120_000L
    private const val DAY_MS = 24L * 60 * 60 * 1000
}
