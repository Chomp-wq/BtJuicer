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
import com.secretsavior.data.Store
import com.secretsavior.vpn.SaviorVpnService

/** Vuelve a levantar lo que se haya caído. Nunca apaga nada. */
object Watchdog {

    private const val TAG = "SecretSavior"

    /** Reinicia el filtro si estaba bloqueado y no corre. Devuelve false si hace falta el usuario. */
    fun ensure(c: Context): Boolean {
        if (!Store.isLocked(c)) return true
        schedule(c)
        if (SaviorVpnService.running) return true
        if (VpnService.prepare(c) != null) return false // otra VPN le quitó el permiso
        return try {
            val i = Intent(c, SaviorVpnService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) c.startForegroundService(i) else c.startService(i)
            true
        } catch (e: Exception) {
            // Android 12+ puede negar arrancar servicios desde segundo plano.
            Log.w(TAG, "no se pudo arrancar el filtro", e)
            false
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
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + delayMs, pi)
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo programar la alarma", e)
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
