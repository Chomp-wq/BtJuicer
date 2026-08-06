package com.btjuicer.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.btjuicer.Juicer

/** Brings the equaliser back after a reboot or an update, if it was on. */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Juicer.init(context)
                if (Juicer.prefs.current.eq.enabled) {
                    runCatching { JuicerService.start(context) }
                }
            }
        }
    }
}
