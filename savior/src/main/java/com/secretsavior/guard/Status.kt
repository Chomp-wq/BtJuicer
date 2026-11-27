package com.secretsavior.guard

import android.Manifest
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
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

    /** Propietaria del dispositivo: la versión dura (sin forzar detención, sin modo seguro...). */
    fun isDeviceOwner(c: Context): Boolean = try {
        (c.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).isDeviceOwnerApp(c.packageName)
    } catch (e: Exception) {
        false
    }

    /** Concedido una vez por ADB: deja a la app reencender su propia accesibilidad. */
    fun hasSecureSettings(c: Context): Boolean =
        c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** Acceso a notificaciones: es lo que hace que Android vuelva a levantar la app tras forzar su detención. */
    fun isReviveEnabled(c: Context): Boolean = try {
        (c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .isNotificationListenerAccessGranted(ComponentName(c, ReviveListener::class.java))
    } catch (e: Exception) {
        false
    }

    /** null si no se sabe (Android 9 o anterior, o el filtro aún no ha arrancado). */
    fun isAlwaysOnVpn(): Boolean? = SaviorVpnService.alwaysOn

    /** «Pausar la actividad si no se usa» apagado: si no, Android puede detener la app sola. */
    fun isAutoRevokeExempt(c: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || try {
            c.packageManager.isAutoRevokeWhitelisted
        } catch (e: Exception) {
            false
        }
}
