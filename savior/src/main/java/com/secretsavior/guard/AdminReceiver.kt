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

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        context.getString(R.string.admin_warning)

    /** Si pese a todo se desactiva, la app lo nota y pide volver a activarlo. */
    override fun onDisabled(context: Context, intent: Intent) {
        if (Store.isLocked(context)) Watchdog.nag(context)
    }
}
