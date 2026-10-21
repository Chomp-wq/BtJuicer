package com.secretsavior

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.secretsavior.data.Store
import com.secretsavior.guard.Status
import com.secretsavior.guard.Watchdog
import com.secretsavior.ui.Actions
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

        override fun enableAdmin() = startActivity(
            Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, Status.adminComponent(this@MainActivity))
                .putExtra(
                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                    "Mientras sea administrador, Android no permite desinstalar Secret Savior.",
                ),
        )

        override fun openNetworkSettings() = startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))

        override fun exemptBattery() {
            Store.openGrace(this@MainActivity)
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
            )
        }

        /** Xiaomi/Redmi/POCO matan los servicios de apps sin «Autoinicio». */
        override fun openAutostart() {
            Store.openGrace(this@MainActivity)
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

        override fun commit() {
            Store.lock(this@MainActivity)
            Watchdog.ensure(this@MainActivity)
        }
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
