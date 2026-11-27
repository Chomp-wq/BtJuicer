package com.secretsavior

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.IntentCompat
import com.secretsavior.data.Store
import com.secretsavior.guard.ReviveListener
import com.secretsavior.guard.Safe
import com.secretsavior.guard.safely
import com.secretsavior.guard.Status
import com.secretsavior.guard.Watchdog
import com.secretsavior.ui.Actions
import com.secretsavior.ui.Hardening
import com.secretsavior.ui.SaviorApp
import com.secretsavior.ui.SaviorTheme
import com.secretsavior.vpn.SaviorVpnService

class MainActivity : ComponentActivity() {

    /**
     * Abrir una pantalla del sistema puede lanzar ActivityNotFoundException (ROM sin esa pantalla)
     * o SecurityException (intent propio de un fabricante, actividad no exportada). Es un clic en
     * el hilo principal: un fallo aquí tumbaría el proceso con el túnel dentro. Devuelve si abrió.
     */
    private fun start(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (t: Throwable) {
        Safe.failed("abrir ${intent.action ?: intent.component?.flattenToShortString()}", t)
        false
    }

    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        safely("consentimiento de VPN") { if (Status.isVpnPermitted(this)) startVpn() }
    }

    private val actions = object : Actions {
        override fun enableVpn() = safely("activar VPN") {
            val consent = VpnService.prepare(this@MainActivity)
            if (consent != null) vpnConsent.launch(consent) else startVpn()
        }

        override fun openAccessibility() {
            start(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }

        override fun openAppInfo() {
            start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }

        override fun enableAdmin() = launchAdmin()

        override fun openNetworkSettings() {
            start(Intent(Settings.ACTION_WIRELESS_SETTINGS))
        }

        override fun exemptBattery() = safely("batería") {
            Store.openGrace(Store.Grace.BATTERY)
            Store.setBatteryAsked(this@MainActivity)
            start(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }

        /** MIUI a veces no concede el diálogo: la lista general de ajustes sí deja hacerlo a mano. */
        override fun openBatteryList() = safely("lista de batería") {
            Store.openGrace(Store.Grace.BATTERY)
            Store.setBatteryListOpened(this@MainActivity)
            val opened = start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            if (!opened) openAppInfo()
        }

        override fun confirmBatteryAnyway() = safely("batería a mano") {
            if (!Store.isLocked(this@MainActivity)) Store.setBatteryContinue(this@MainActivity)
        }

        override fun confirmAutostart() = safely("autoinicio a mano") {
            if (!Store.isLocked(this@MainActivity)) Store.setAutostartSeen(this@MainActivity)
        }

        override fun confirmAutoRevoke() = safely("pausa a mano") {
            if (!Store.isLocked(this@MainActivity)) Store.setAutoRevokeConfirmed(this@MainActivity)
        }

        /** Xiaomi/Redmi/POCO matan los servicios de apps sin «Autoinicio». */
        override fun openAutostart() = safely("autoinicio") {
            Store.openGrace(Store.Grace.AUTOSTART)
            Store.setAutostartOpened(this@MainActivity)
            val miui = Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            )
            if (!start(miui)) openAppInfo()
        }

        override fun openNotificationAccess() = safely("acceso a notificaciones") {
            Store.openGrace(Store.Grace.NOTIFICATION_ACCESS)
            val me = ComponentName(this@MainActivity, ReviveListener::class.java)
            val opened = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                start(
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                        .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, me.flattenToString()),
                )
            if (!opened) start(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        override fun openVpnSettings() = safely("VPN siempre activa") {
            Store.openGrace(Store.Grace.ALWAYS_ON_VPN)
            start(Intent(Settings.ACTION_VPN_SETTINGS))
        }

        override fun openAutoRevoke() = safely("pausar permisos") {
            Store.openGrace(Store.Grace.AUTO_REVOKE)
            Store.setAutoRevokeOpened(this@MainActivity)
            // androidx elige la pantalla de cada versión; en MIUI puede no existir ese interruptor.
            val opened = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && try {
                start(IntentCompat.createManageUnusedAppRestrictionsIntent(this@MainActivity, packageName))
            } catch (t: Throwable) {
                Safe.failed("intent de pausa por inactividad", t)
                false
            }
            if (!opened) openAppInfo()
        }

        override fun openDevOptions() {
            if (!start(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))) start(Intent(Settings.ACTION_SETTINGS))
        }

        override fun copy(text: String) = safely("copiar") {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("comando", text))
            Toast.makeText(this@MainActivity, "Copiado.", Toast.LENGTH_SHORT).show()
        }

        override fun harden(kind: Hardening) = safely("endurecer") {
            when (kind) {
                Hardening.DEV_OPTIONS -> Store.blockDevOptions(this@MainActivity)
                Hardening.ADB -> Store.blockAdb(this@MainActivity)
            }
            Watchdog.ensure(this@MainActivity)
        }

        override fun beginOwnerCommit() = safely("empezar bloqueo") {
            Store.setPendingCommit(this@MainActivity, true)
        }

        override fun cancelCommit() = safely("cancelar bloqueo") {
            Store.setPendingCommit(this@MainActivity, false)
        }

        /**
         * Lo último de todo: el administrador es lo que bloquea (ver Store.isLocked), así que
         * pedirlo antes dejaba la app bloqueada a mitad de la configuración.
         */
        override fun commit() = safely("bloquear") {
            Store.setPendingCommit(this@MainActivity, true)
            if (Status.isAdminActive(this@MainActivity)) {
                finishCommit()
            } else {
                launchAdmin()
            }
        }
    }

    private val adminConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        safely("resultado del administrador") {
            if (it.resultCode == RESULT_OK || Status.isAdminActive(this)) {
                finishCommit()
            } else if (Store.pendingCommit(this)) {
                Store.setPendingCommit(this, false)
                Toast.makeText(
                    this,
                    "No se activó nada: sin el administrador la protección no queda fija. Cuando quieras, vuelve a intentarlo.",
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    private fun launchAdmin() = safely("pedir administrador") {
        adminConsent.launch(
            Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, Status.adminComponent(this))
                .putExtra(
                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                    "Mientras sea administrador, Android no permite desinstalar Secret Savior.",
                ),
        )
    }

    private fun finishCommit() = safely("terminar bloqueo") {
        Store.lock(this)
        Store.setPendingCommit(this, false)
        Watchdog.ensure(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Sin permiso de notificaciones el aviso fijo no se ve, aunque el servicio corra igual.
        safely("permiso de notificaciones") {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        }
        setContent { SaviorTheme { SaviorApp(actions) } }
    }

    override fun onResume() {
        super.onResume()
        safely("al volver") {
            if (Store.isLocked(this)) Watchdog.ensure(this)
            Status.refreshUnusedRestrictions(this)
        }
    }

    private fun startVpn() = safely("arrancar el filtro") {
        // Android 12+ lo rechaza desde segundo plano (ForegroundServiceStartNotAllowedException).
        startForegroundService(Intent(this, SaviorVpnService::class.java))
    }
}
