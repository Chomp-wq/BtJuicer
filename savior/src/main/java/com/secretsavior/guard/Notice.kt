package com.secretsavior.guard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import com.secretsavior.MainActivity
import com.secretsavior.R

/** La notificación fija que acompaña al filtro mientras corre en primer plano. */
object Notice {

    const val ID = 1
    private const val CHANNEL = "protection"

    fun build(c: Context): Notification {
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Protección", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Indica que el filtro de Secret Savior está activo."
                setShowBadge(false)
            },
        )
        val open = PendingIntent.getActivity(
            c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Secret Savior")
            .setContentText("Protección activa")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    // --- Avisos: desde Android 10 no se puede abrir una actividad desde segundo plano ---

    const val ALERT_FILTER = 2
    const val ALERT_GUARD = 3
    private const val ALERT_CHANNEL = "alerts"
    private const val ALERT_GAP_MS = 10 * 60_000L

    private val gates = HashMap<Int, Throttle>()

    /**
     * Aviso de alta importancia, con un mínimo de 10 min entre avisos del mismo tipo; al
     * tocarlo se abre la app. Nunca lanza (sin permiso de notificaciones simplemente no sale).
     */
    fun alert(c: Context, id: Int, title: String, text: String) {
        try {
            val gate = synchronized(gates) { gates.getOrPut(id) { Throttle(ALERT_GAP_MS) } }
            if (!gate.tryPass(SystemClock.elapsedRealtime())) return
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL, c.getString(R.string.alert_channel), NotificationManager.IMPORTANCE_HIGH),
            )
            val open = PendingIntent.getActivity(
                c, id, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            nm.notify(
                id,
                Notification.Builder(c, ALERT_CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(Notification.BigTextStyle().bigText(text))
                    .setAutoCancel(true)
                    .setContentIntent(open)
                    .build(),
            )
        } catch (e: Throwable) {
            Log.w("SecretSavior", "no se pudo avisar", e)
        }
    }
}
