package com.secretsavior.guard

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import com.secretsavior.R
import com.secretsavior.data.Store

/**
 * Mientras esta app sea administrador del dispositivo, Android no deja
 * desinstalarla. Quitarla de la lista de administradores es la única ruta, y es
 * la pantalla que [GuardService] cierra en cuanto aparece.
 */
class AdminReceiver : DeviceAdminReceiver() {

    /**
     * El administrador se pide al final, con «Activar y bloquear»: es el momento en que se
     * bloquea. También ocurre al volverse propietaria del dispositivo (que lo activa sola).
     */
    override fun onEnabled(context: Context, intent: Intent) {
        safely("administrador activado") {
            Store.lock(context)
            Store.setPendingCommit(context, false)
            Watchdog.ensure(context)
        }
    }

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        safelyOr("aviso de administrador", "") { context.getString(R.string.admin_warning) }

    /** Si pese a todo se desactiva, la app lo nota y pide volver a activarlo. */
    override fun onDisabled(context: Context, intent: Intent) {
        safely("administrador desactivado") { if (Store.isLocked(context)) Watchdog.nag(context) }
    }
}
