package com.secretsavior.guard

import android.service.notification.NotificationListenerService

/**
 * Esqueleto: lo completa el trabajo de resurrección. Android vuelve a enlazar los servicios de
 * escucha de notificaciones tras forzar la detención de su app; eso basta para volver a arrancar.
 * No lee ninguna notificación.
 */
class ReviveListener : NotificationListenerService() {
    override fun onListenerConnected() {
        Watchdog.ensure(applicationContext)
    }
}
