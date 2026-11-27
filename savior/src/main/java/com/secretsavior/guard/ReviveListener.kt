package com.secretsavior.guard

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.util.Log

/**
 * Resurrección: al forzar la detención de la app, Android derriba sus servicios enlazados y
 * vuelve a enlazar los oyentes de notificaciones aprobados (ACTION_PACKAGE_RESTARTED /
 * onBindingDied). Eso arranca nuestro proceso, y aquí se levanta lo demás.
 * No lee ninguna notificación: no sobrescribe onNotificationPosted ni nada parecido.
 */
class ReviveListener : NotificationListenerService() {

    override fun onListenerConnected() {
        connected = true
        safely("oyente conectado") { Watchdog.ensure(applicationContext) }
    }

    override fun onListenerDisconnected() {
        connected = false
        safely("oyente desconectado") { rebind(applicationContext) }
    }

    companion object {
        /** En memoria: si el proceso muere, empieza en false, que es lo cierto. */
        @Volatile
        var connected = false
            private set

        /** Pide a Android que vuelva a enlazar el oyente. Nunca lanza. */
        fun rebind(c: android.content.Context) {
            try {
                requestRebind(ComponentName(c, ReviveListener::class.java))
            } catch (e: Throwable) {
                Log.w("SecretSavior", "no se pudo reenlazar el oyente", e)
            }
        }
    }
}
