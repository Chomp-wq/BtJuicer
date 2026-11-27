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
import com.secretsavior.data.Store
import com.secretsavior.guard.ReviveListener
import com.secretsavior.guard.Status
import com.secretsavior.guard.Watchdog
import com.secretsavior.ui.Actions
import com.secretsavior.ui.Hardening
import com.secretsavior.ui.SaviorApp
import com.secretsavior.ui.SaviorTheme
import com.secretsavior.vpn.SaviorVpnService

class MainActivity : ComponentActivity() {

    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (Status.isVpnPermitted(this)) startVpn()
    }

    private val actions = object : Actions {
        override fun enableVpn() {
            val consent = VpnService.prepare(this@MainActivity)
            if (consent != null) vpnConsent.launch(consent) else startVpn()
        }

        override fun openAccessibility() =
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))

        override fun openAppInfo() = startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
        )

        override fun enableAdmin() = launchAdmin()

        override fun openNetworkSettings() = startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))

        override fun exemptBattery() {
            Store.openGrace(Store.Grace.BATTERY)
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
            )
        }

        /** Xiaomi/Redmi/POCO matan los servicios de apps sin «Autoinicio». */
        override fun openAutostart() {
            Store.openGrace(Store.Grace.AUTOSTART)
            try {
                startActivity(
                    Intent().setComponent(
                        ComponentName(
                            "com.miui.securitycenter",
                            "com.miui.permcenter.autostart.AutoStartManagementActivity",
                        ),
                    ),
                )
            } catch (e: Exception) {
                openAppInfo()
            }
        }

        override fun openNotificationAccess() {
            Store.openGrace(Store.Grace.NOTIFICATION_ACCESS)
            val me = ComponentName(this@MainActivity, ReviveListener::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, me.flattenToString()),
                    )
                } else {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                }
            } catch (e: Exception) {
                runCatching { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
            }
        }

        override fun openVpnSettings() {
            Store.openGrace(Store.Grace.ALWAYS_ON_VPN)
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
        }

        override fun openAutoRevoke() {
            Store.openGrace(Store.Grace.AUTO_REVOKE)
            try {
                startActivity(
                    Intent(Intent.ACTION_AUTO_REVOKE_PERMISSIONS, Uri.parse("package:$packageName")),
                )
            } catch (e: Exception) {
                openAppInfo()
            }
        }

        override fun openDevOptions() {
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            }
        }

        override fun copy(text: String) {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("comando", text))
            Toast.makeText(this@MainActivity, "Copiado.", Toast.LENGTH_SHORT).show()
        }

        override fun harden(kind: Hardening) {
            when (kind) {
                Hardening.DEV_OPTIONS -> Store.blockDevOptions(this@MainActivity)
                Hardening.ADB -> Store.blockAdb(this@MainActivity)
            }
            Watchdog.ensure(this@MainActivity)
        }

        override fun beginOwnerCommit() {
            Store.setPendingCommit(this@MainActivity, true)
        }

        override fun cancelCommit() {
            Store.setPendingCommit(this@MainActivity, false)
        }

        /**
         * Lo último de todo: el administrador es lo que bloquea (ver Store.isLocked), así que
         * pedirlo antes dejaba la app bloqueada a mitad de la configuración.
         */
        override fun commit() {
            Store.setPendingCommit(this@MainActivity, true)
            if (Status.isAdminActive(this@MainActivity)) {
                finishCommit()
            } else {
                launchAdmin()
            }
        }
    }

    private val adminConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
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

    private fun launchAdmin() {
        adminConsent.launch(
            Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, Status.adminComponent(this))
                .putExtra(
                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                    "Mientras sea administrador, Android no permite desinstalar Secret Savior.",
                ),
        )
    }

    private fun finishCommit() {
        Store.lock(this)
        Store.setPendingCommit(this, false)
        Watchdog.ensure(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Sin permiso de notificaciones el aviso fijo no se ve, aunque el servicio corra igual.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        setContent { SaviorTheme { SaviorApp(actions) } }
    }

    override fun onResume() {
        super.onResume()
        if (Store.isLocked(this)) Watchdog.ensure(this)
    }

    private fun startVpn() {
        startForegroundService(Intent(this, SaviorVpnService::class.java))
    }
}
