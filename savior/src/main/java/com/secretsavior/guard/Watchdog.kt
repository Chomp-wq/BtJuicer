package com.secretsavior.guard

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.R
import com.secretsavior.data.Store
import com.secretsavior.vpn.SaviorVpnService

/** Vuelve a levantar lo que se haya caído. Nunca apaga nada. */
object Watchdog {

    private const val TAG = "SecretSavior"

    /**
     * Levanta todo lo que se haya caído. Devuelve false si hace falta el usuario.
     * Cada parte va aparte: que una falle no impide las demás.
     */
    fun ensure(c: Context): Boolean {
        if (!Store.isLocked(c)) return true
        val app = c.applicationContext
        schedule(app)
        val ok = ensureVpn(app)
        guarded("autocuración") {
            SelfHeal.watch(app)
            SelfHeal.heal(app)
        }
        guarded("propietaria") {
            Owner.apply(app)
            Owner.syncSuspension(app)
        }
        guarded("oyente") { rebindListener(app) }
        guarded("guardián") {
            if (!Status.isGuardEnabled(app) && !Status.hasSecureSettings(app)) {
                Notice.alert(app, Notice.ALERT_GUARD, app.getString(R.string.alert_guard_title), app.getString(R.string.alert_guard_text))
            }
        }
        return ok
    }

    private fun ensureVpn(c: Context): Boolean {
        if (SaviorVpnService.running) return true
        if (VpnService.prepare(c) != null) return false // otra VPN le quitó el permiso
        return try {
            val i = Intent(c, SaviorVpnService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) c.startForegroundService(i) else c.startService(i)
            true
        } catch (e: Exception) {
            // Android 12+ lanza ForegroundServiceStartNotAllowedException desde segundo plano si
            // la app no está exenta de batería: no se puede arrancar solo, se avisa.
            Log.w(TAG, "no se pudo arrancar el filtro", e)
            alertFilter(c)
            false
        }
    }

    private fun alertFilter(c: Context) =
        Notice.alert(c, Notice.ALERT_FILTER, c.getString(R.string.alert_filter_title), c.getString(R.string.alert_filter_text))

    private val rebindGate = Throttle(30_000L)

    /** Aprobado pero desenlazado: Android no lo vuelve a enlazar solo siempre; se le pide. */
    private fun rebindListener(c: Context) {
        if (ReviveListener.connected || !Status.isReviveEnabled(c)) return
        if (rebindGate.tryPass(SystemClock.elapsedRealtime())) ReviveListener.rebind(c)
    }

    private inline fun guarded(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            Log.w(TAG, "watchdog: $name", e)
        }
    }

    const val ACTION = "com.secretsavior.WATCHDOG"
    private const val PERIOD_MS = 5 * 60_000L

    @Volatile
    private var lastScheduled = Long.MIN_VALUE / 2

    /**
     * Una alarma que sobrevive a que cierren la app: si el proceso muere, el sistema
     * lo vuelve a levantar para pasar lista. [BootReceiver] la atiende y la renueva.
     */
    fun schedule(c: Context, delayMs: Long = PERIOD_MS) {
        // ensure() la renueva cada pocos segundos; no hace falta hablar con el sistema cada vez.
        val now = SystemClock.elapsedRealtime()
        if (delayMs == PERIOD_MS && now - lastScheduled < PERIOD_MS / 2) return
        if (delayMs == PERIOD_MS) lastScheduled = now
        try {
            val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = PendingIntent.getBroadcast(
                c, 0, Intent(c, BootReceiver::class.java).setAction(ACTION),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val at = SystemClock.elapsedRealtime() + delayMs
            if (delayMs == PERIOD_MS) {
                // La ronda periódica no despierta al teléfono: si duerme, nadie navega. Se
                // entrega en cuanto despierte, y no gasta batería con la pantalla apagada.
                am.set(AlarmManager.ELAPSED_REALTIME, at, pi)
            } else {
                // Volver tras cerrar la app sí corre prisa.
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo programar la alarma", e)
        }
    }

    /**
     * Trae la app al frente para que el usuario repare lo que falta. Desde Android 10 el sistema
     * no deja abrir actividades desde segundo plano (y no lo dice), así que además va un aviso.
     */
    fun nag(c: Context) {
        var failed = false
        try {
            c.startActivity(
                Intent(c, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            )
        } catch (e: Exception) {
            failed = true
            Log.w(TAG, "no se pudo abrir la app", e)
        }
        if (failed || Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val app = c.applicationContext
            Notice.alert(app, Notice.ALERT_FILTER, app.getString(R.string.alert_nag_title), app.getString(R.string.alert_nag_text))
        }
    }
}
