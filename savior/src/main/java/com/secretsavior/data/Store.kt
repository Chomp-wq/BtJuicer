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
     *
     * Por eso el administrador se pide *el último* (botón «Activar y bloquear»): pedirlo
     * antes bloquearía la app a mitad de la configuración.
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

    /** Guarda ya lo contado; si no, lo de los últimos segundos se pierde al morir el proceso. */
    fun flushNow(c: Context) = flush(c, SystemClock.elapsedRealtime())

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
     * Qué pantalla de Ajustes puede abrir la app, con el bloqueo ya activo, para conceder algo
     * que falta. El guardián sólo deja pasar la pantalla de ese tipo, y nunca las que ofrecen
     * forzar la detención, desinstalar, borrar datos, desactivar el administrador o desconectar.
     */
    enum class Grace { BATTERY, AUTOSTART, NOTIFICATION_ACCESS, ALWAYS_ON_VPN, AUTO_REVOKE }

    /** Sólo se abre desde dentro de la app (ver GuardService). */
    fun openGrace(kind: Grace) {
        graceKind = kind
        graceUntil = SystemClock.elapsedRealtime() + GRACE_MS
    }

    /**
     * En memoria y con el reloj de arranque, no con la hora del sistema: guardada con la
     * hora, bastaba atrasar el reloj del teléfono para dejar la ventana abierta para siempre.
     */
    fun inGrace(): Boolean = SystemClock.elapsedRealtime() < graceUntil

    /** La ventana abierta ahora mismo, o null. */
    fun grace(): Grace? = if (inGrace()) graceKind else null

    @Volatile
    private var graceUntil = 0L

    @Volatile
    private var graceKind: Grace? = null

    /** Se ha visto el autoinicio de la app encendido: desde entonces no se deja apagar. */
    fun autostartSeen(c: Context): Boolean = prefs(c).getBoolean("autostart_seen", false)

    fun setAutostartSeen(c: Context) {
        if (isLocked(c)) return // ya bloqueada no se confirma nada a mano
        if (!autostartSeen(c)) prefs(c).edit().putBoolean("autostart_seen", true).apply()
    }

    /*
     * Ayudas de la configuración inicial para móviles que no informan de un ajuste (MIUI). Sólo
     * existen antes de bloquear: con el bloqueo activo ninguna cambia nada ni sustituye a lo
     * detectado, y las filas de la pantalla bloqueada siguen mostrando el estado real.
     */
    private fun flag(c: Context, key: String) = prefs(c).getBoolean(key, false)

    private fun setFlag(c: Context, key: String) {
        if (isLocked(c)) return
        if (!flag(c, key)) prefs(c).edit().putBoolean(key, true).apply()
    }

    /** El usuario ya abrió esa pantalla desde la app (condición para ofrecer «ya está»). */
    fun autostartOpened(c: Context) = flag(c, "autostart_opened")
    fun setAutostartOpened(c: Context) = setFlag(c, "autostart_opened")

    fun batteryAsked(c: Context) = flag(c, "battery_asked")
    fun setBatteryAsked(c: Context) = setFlag(c, "battery_asked")

    fun batteryListOpened(c: Context) = flag(c, "battery_list_opened")
    fun setBatteryListOpened(c: Context) = setFlag(c, "battery_list_opened")

    /** «Continuar de todos modos» en batería: sólo cuenta para poder terminar la configuración. */
    fun batteryContinue(c: Context) = flag(c, "battery_continue")
    fun setBatteryContinue(c: Context) = setFlag(c, "battery_continue")

    fun autoRevokeOpened(c: Context) = flag(c, "autorevoke_opened")
    fun setAutoRevokeOpened(c: Context) = setFlag(c, "autorevoke_opened")

    fun autoRevokeConfirmed(c: Context) = flag(c, "autorevoke_confirmed")
    fun setAutoRevokeConfirmed(c: Context) = setFlag(c, "autorevoke_confirmed")

    /** Las razones propias, para leerlas justo cuando más falta hacen. */
    fun reason(c: Context): String = prefs(c).getString("reason", "").orEmpty()

    fun setReason(c: Context, text: String) {
        prefs(c).edit().putString("reason", text.take(600)).apply()
    }

    // --- Endurecimiento: como todo lo demás, sólo se puede encender ---------------------

    /** El usuario pulsó «Activar y bloquear»: falta que Android confirme el administrador. */
    fun pendingCommit(c: Context): Boolean = prefs(c).getBoolean("pending_commit", false)

    fun setPendingCommit(c: Context, pending: Boolean) {
        prefs(c).edit().putBoolean("pending_commit", pending).apply()
    }

    /**
     * Opciones de desarrollador cerradas mientras dure el bloqueo (cierra la vía de ADB; también
     * deja sin depuración inalámbrica a BT Juicer). De ida.
     */
    fun devOptionsBlocked(c: Context): Boolean = prefs(c).getBoolean("block_dev", false)

    fun blockDevOptions(c: Context) {
        prefs(c).edit().putBoolean("block_dev", true).apply()
    }

    /** Sólo como propietaria del dispositivo: ADB prohibido por política del sistema. De ida. */
    fun adbBlocked(c: Context): Boolean = prefs(c).getBoolean("block_adb", false)

    fun blockAdb(c: Context) {
        prefs(c).edit().putBoolean("block_adb", true).apply()
    }

    private const val FLUSH_MS = 30_000L
    private const val GRACE_MS = 120_000L
    private const val DAY_MS = 24L * 60 * 60 * 1000
}
