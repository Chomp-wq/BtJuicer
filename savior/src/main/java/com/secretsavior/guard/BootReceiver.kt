package com.secretsavior.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.secretsavior.data.Store

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Store.isLocked(context)) Watchdog.ensure(context)
    }
}
