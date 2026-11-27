package com.secretsavior.guard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
}
