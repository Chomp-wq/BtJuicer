package com.secretsavior.guard

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.net.VpnService
import android.os.PowerManager
import android.provider.Settings
import com.secretsavior.vpn.SaviorVpnService

/** Preguntas al sistema sobre cada una de las capas de protección. */
object Status {

    fun adminComponent(c: Context) = ComponentName(c, AdminReceiver::class.java)

    fun isAdminActive(c: Context): Boolean =
        (c.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
            .isAdminActive(adminComponent(c))

    fun isGuardEnabled(c: Context): Boolean {
        val me = ComponentName(c, GuardService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(
            c.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ).orEmpty()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }

    /** El usuario ya aceptó el diálogo del sistema de la VPN. */
    fun isVpnPermitted(c: Context): Boolean = VpnService.prepare(c) == null

    fun isVpnRunning(): Boolean = SaviorVpnService.running

    /**
     * Con DNS privado en modo "nombre de host", Android cifra las consultas hacia
     * ese proveedor y se salta el filtro. "Automático" y "Desactivado" sirven.
     */
    fun isPrivateDnsStrict(c: Context): Boolean =
        Settings.Global.getString(c.contentResolver, "private_dns_mode") == "hostname"

    fun isBatteryExempt(c: Context): Boolean =
        (c.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(c.packageName)
}
