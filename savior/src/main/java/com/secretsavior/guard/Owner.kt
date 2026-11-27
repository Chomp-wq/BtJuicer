package com.secretsavior.guard

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.provider.Telephony
import android.util.Log
import android.webkit.WebView
import com.secretsavior.data.Store

/**
 * Políticas de propietaria del dispositivo (sólo si la app lo es y el bloqueo está activo).
 * Cada llamada va en su propio try/catch: las ROM de fabricante lanzan excepciones raras y una
 * no debe impedir las demás. Es idempotente y [apply] se acelera sola.
 */
object Owner {

    private const val TAG = "SecretSavior"
    private const val APPLY_GAP_MS = 60_000L
    private const val PREFS = "savior_owner"
    private const val KEY_SUSPENDED = "suspended"

    private val throttle = Throttle(APPLY_GAP_MS)

    private fun dpm(c: Context) = c.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    private fun eligible(c: Context) = Store.isLocked(c) && Status.isDeviceOwner(c)

    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) { // también NoSuchMethodError & co. de ROM raras
            Log.w(TAG, "propietaria: $name", e)
        }
    }

    fun apply(c: Context, force: Boolean = false) {
        val app = c.applicationContext
        if (!eligible(app)) return
        if (!force && !throttle.tryPass(SystemClock.elapsedRealtime())) return
        val d = dpm(app)
        val admin = Status.adminComponent(app)
        val me = app.packageName

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Sin «Forzar detención» ni «Borrar datos» para nuestro paquete.
            step("setUserControlDisabledPackages") {
                if (me !in d.getUserControlDisabledPackages(admin)) d.setUserControlDisabledPackages(admin, listOf(me))
            }
        }
        step("setUninstallBlocked") {
            if (!d.isUninstallBlocked(admin, me)) d.setUninstallBlocked(admin, me, true)
        }
        step("setAlwaysOnVpnPackage") {
            // Sin «lockdown»: el túnel sólo lleva DNS y bloquear lo demás dejaría el móvil sin internet.
            if (d.getAlwaysOnVpnPackage(admin) != me) d.setAlwaysOnVpnPackage(admin, me, false)
        }
        step("restricciones") {
            val have = d.getUserRestrictions(admin)
            for (r in OwnerPolicy.restrictions(Build.VERSION.SDK_INT, Store.adbBlocked(app))) {
                if (!have.getBoolean(r, false)) step(r) { d.addUserRestriction(admin, r) }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            step("setGlobalPrivateDnsModeOpportunistic") {
                // Sólo si hay DNS estricto: «apagado» y «automático» ya sirven y no hay por qué pisarlos.
                if (Status.isPrivateDnsStrict(app)) {
                    d.setGlobalPrivateDnsModeOpportunistic(admin)
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            step("POST_NOTIFICATIONS") {
                val p = Manifest.permission.POST_NOTIFICATIONS
                if (d.getPermissionGrantState(admin, me, p) != DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED) {
                    d.setPermissionGrantState(admin, me, p, DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
                }
            }
        }
        for (pkg in OwnerPolicy.HIDDEN_APPS) { // misma lista que GuardService.BLOCKED_APPS
            step("setApplicationHidden $pkg") {
                if (installed(app, pkg) && !d.isApplicationHidden(admin, pkg)) d.setApplicationHidden(admin, pkg, true)
            }
        }
    }

    // --- Navegadores: sin guardián no hay navegador ----------------------------------------

    @Volatile
    private var brokenSince = SuspendGate.NOT_BROKEN

    /**
     * Se llama en cada ronda de [Watchdog.ensure]. Si la protección lleva ≥ 20 s rota se
     * suspenden los navegadores; en cuanto vuelve, se devuelven exactamente los suspendidos.
     * El conjunto va a disco *antes* de suspender, y cada ronda revisa si hay que levantarlo.
     */
    @Synchronized
    fun syncSuspension(c: Context) {
        val app = c.applicationContext
        val saved = suspended(app)
        val broken = try {
            !Status.isVpnRunning() || !Status.isGuardEnabled(app) || Status.isPrivateDnsStrict(app)
        } catch (e: Exception) {
            false // sin poder saberlo no se castiga a nadie
        }
        val dec = SuspendGate.decide(
            eligible = eligible(app), broken = broken, brokenSince = brokenSince,
            now = SystemClock.elapsedRealtime(), suspended = saved.isNotEmpty(),
        )
        brokenSince = dec.brokenSince
        when (dec.action) {
            SuspendGate.Action.NONE -> {}
            SuspendGate.Action.SUSPEND -> step("suspender navegadores") { suspend(app) }
            SuspendGate.Action.LIFT -> step("devolver navegadores") { lift(app, saved) }
        }
    }

    private fun suspend(c: Context) {
        Browsers.refresh(c) // por si se instaló alguno desde la última vez
        val targets = SuspendGate.targets(Browsers.all(), protectedPackages(c)) { installed(c, it) }
        if (targets.isEmpty()) return
        saveSuspended(c, targets.toSet())
        dpm(c).setPackagesSuspended(Status.adminComponent(c), targets.toTypedArray(), true)
    }

    private fun lift(c: Context, saved: Set<String>) {
        dpm(c).setPackagesSuspended(Status.adminComponent(c), saved.toTypedArray(), false)
        saveSuspended(c, emptySet()) // si lanzó (p. ej. ya no somos propietaria), se reintenta
    }

    /** Lo que nunca se suspende: nosotros, lanzador, teléfono, SMS, Ajustes, SystemUI y el WebView. */
    private fun protectedPackages(c: Context): Set<String> {
        val s = HashSet<String>()
        s += c.packageName
        s += listOf("com.android.settings", "com.android.systemui", "android")
        step("lanzador") { homePackage(c)?.let(s::add) }
        step("teléfono") {
            val i = Intent(Intent.ACTION_DIAL).setData(android.net.Uri.parse("tel:"))
            c.packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName?.let(s::add)
        }
        step("SMS") { Telephony.Sms.getDefaultSmsPackage(c)?.let(s::add) }
        step("webview") { WebView.getCurrentWebViewPackage()?.packageName?.let(s::add) }
        return s
    }

    private fun homePackage(c: Context): String? {
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        return c.packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
    }

    private fun installed(c: Context, pkg: String): Boolean = try {
        c.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun suspended(c: Context): Set<String> = prefs(c).getStringSet(KEY_SUSPENDED, emptySet()).orEmpty().toSet()

    private fun saveSuspended(c: Context, set: Set<String>) {
        prefs(c).edit().putStringSet(KEY_SUSPENDED, set).commit() // commit: tiene que estar en disco ya
    }
}
