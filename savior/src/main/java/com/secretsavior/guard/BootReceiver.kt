package com.secretsavior.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.secretsavior.data.Store

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // También renueva la alarma. Un fallo aquí no puede tumbar el proceso (lleva el túnel).
        safely("arranque") { if (Store.isLocked(context)) Watchdog.ensure(context) }
    }
}
