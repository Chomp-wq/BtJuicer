package com.secretsavior.guard

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import com.secretsavior.data.Store
import com.secretsavior.vpn.DnsFilter

/**
 * El guardián. Hace tres cosas, todas locales:
 *
 *  1. Cierra las pantallas del sistema desde las que se podría apagar la
 *     protección (ficha de la app en Ajustes, desinstalar, administradores,
 *     accesibilidad, VPN, DNS privado).
 *  2. Cierra el navegador si apunta a un sitio bloqueado o si el filtro DNS está
 *     caído —falla cerrado, no abierto—.
 *  3. Cierra lo que se escribe si es texto pornográfico.
 *
 * "Cerrar" es mandar al inicio. Nada de lo que ve se guarda ni se envía.
 */
class GuardService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    private var lastBlock = 0L
    private var lastNag = 0L

    private val tick = object : Runnable {
        override fun run() {
            patrol()
            handler.postDelayed(this, PATROL_MS)
        }
    }

    override fun onServiceConnected() {
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    override fun onInterrupt() = Unit

    /** Comprobación periódica: levanta el filtro y avisa si falta algo que sólo el usuario puede dar. */
    private fun patrol() {
        if (!Store.isLocked(this)) return
        val vpnOk = Watchdog.ensure(this)
        val broken = !vpnOk || !Status.isAdminActive(this)
        val now = SystemClock.elapsedRealtime()
        if (broken && now - lastNag > NAG_MS) {
            lastNag = now
            Watchdog.nag(this)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName) return
        if (!Store.isLocked(this)) return

        if (pkg in BLOCKED_APPS) {
            // Aunque la red falle o la app traiga contenido en caché, no se queda abierta.
            if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) block(countIt = true)
            return
        }

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> onTyped(event, pkg)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> onScreen(pkg)
        }
    }

    private fun onTyped(event: AccessibilityEvent, pkg: String) {
        if (event.isPassword) return
        val text = event.text.joinToString(" ")
        if (ContentRules.isExplicit(text, inBrowser = pkg in BROWSERS || pkg in SEARCH_APPS)) {
            block(countIt = true)
        }
    }

    private fun onScreen(pkg: String) {
        val root = rootInActiveWindow ?: return
        if (root.packageName?.toString() != pkg) return // el evento no es de la ventana activa

        when {
            isSystemSurface(pkg) -> guardSystemScreen(pkg, root)
            pkg in BROWSERS -> guardBrowser(root)
        }
    }

    // --- 1. Pantallas del sistema ---------------------------------------------------

    private fun guardSystemScreen(pkg: String, root: AccessibilityNodeInfo) {
        if (pkg.contains("vpndialogs")) {
            // Si aún no hay permiso de VPN, el diálogo es el de pedirlo y hay que dejarlo pasar.
            // Con permiso, cualquier diálogo que nombre a la app es el de "Desconectar".
            if (!Status.isVpnPermitted(this)) return
            if (mentions(root, OURS)) block(countIt = false)
            return
        }
        // Sin administrador activo el usuario necesita llegar a la pantalla de activarlo.
        if (!Status.isAdminActive(this)) return
        if (mentions(root, OURS)) {
            // Tras pulsar «excluir de batería»/«autoinicio» en la app: dejar esas pantallas,
            // pero nunca las que ofrecen desinstalar, parar, administrar o desconectar.
            if (Store.inGrace(this) && !mentions(root, DANGEROUS)) return
            block(countIt = false)
            return
        }
        // Con DNS privado estricto los navegadores quedan cerrados (ver guardBrowser); hay
        // que dejar llegar al editor para quitarlo, o se quedarían cerrados para siempre.
        if (!Status.isPrivateDnsStrict(this) && mentions(root, PRIVATE_DNS_EDITOR)) block(countIt = false)
    }

    private fun isSystemSurface(pkg: String): Boolean =
        SYSTEM_SURFACES.any { pkg.contains(it) }

    // --- 2. Navegadores -------------------------------------------------------------

    private fun guardBrowser(root: AccessibilityNodeInfo) {
        if (!isProtected()) {
            // Sin filtro no hay navegación. Se trae la app para que el usuario lo repare.
            block(countIt = false)
            Watchdog.nag(this)
            return
        }
        val text = urlBarText(root) ?: return
        if (looksBlocked(text)) block(countIt = true)
    }

    /** El filtro corre y nadie lo esquiva con DNS privado estricto. */
    private fun isProtected(): Boolean = Status.isVpnRunning() && !Status.isPrivateDnsStrict(this)

    private fun looksBlocked(raw: String): Boolean {
        val t = raw.trim()
        if (t.isEmpty()) return false
        if (ContentRules.isExplicit(t, inBrowser = true)) return true
        if (' ' in t) return false
        val host = t.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore(':')
        return DnsFilter.isBlocked(host)
    }

    private fun urlBarText(root: AccessibilityNodeInfo): String? {
        var budget = MAX_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            val id = n.viewIdResourceName.orEmpty().lowercase()
            if (URL_BAR_IDS.any { id.contains(it) }) {
                n.text?.let { return it.toString() }
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        return null
    }

    // --- utilidades -----------------------------------------------------------------

    private fun mentions(root: AccessibilityNodeInfo, needles: List<String>): Boolean {
        var budget = MAX_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            val s = "${n.text ?: ""} ${n.contentDescription ?: ""}".lowercase()
            if (needles.any { s.contains(it) }) return true
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        return false
    }

    private fun block(countIt: Boolean) {
        performGlobalAction(GLOBAL_ACTION_HOME)
        val now = SystemClock.elapsedRealtime()
        if (now - lastBlock > TOAST_MS) {
            Toast.makeText(this, "Secret Savior: bloqueado. Respira, esto pasa.", Toast.LENGTH_SHORT).show()
            if (countIt) Store.countBlock(this)
        }
        lastBlock = now
    }

    private companion object {
        const val PATROL_MS = 10_000L
        const val NAG_MS = 60_000L
        const val TOAST_MS = 3_000L
        const val MAX_NODES = 600

        /** Cómo se llama la app en pantalla, y su paquete (algunas capas del sistema lo muestran). */
        val OURS = listOf("secret savior", "com.secretsavior")

        /** Si aparece alguna de éstas junto al nombre de la app, la pantalla no es de batería. */
        val DANGEROUS = listOf(
            "desinstalar", "uninstall", "forzar", "force stop", "borrar datos", "clear data",
            "almacenamiento", "storage", "administrador", "administrator", "accesibilidad",
            "accessibility", "desconectar", "disconnect", "olvidar", "forget", "vpn",
        )

        /**
         * El campo para escribir el servidor de DNS privado. La fila "DNS privado:
         * Automático" de la pantalla de red no lo contiene, así que Wi-Fi y red
         * siguen accesibles.
         */
        val PRIVATE_DNS_EDITOR = listOf(
            "provider hostname", "proveedor de dns privado", "provedor de dns privado",
            "fournisseur de dns privé", "dns-anbieters",
        )

        /** Ajustes, instalador, permisos, VPN y las capas de cada fabricante. */
        val SYSTEM_SURFACES = listOf(
            "settings", "packageinstaller", "permissioncontroller", "vpndialogs",
            "securitycenter", "safecenter", "systemmanager", "devicecare", "lool", "vending",
        )

        val URL_BAR_IDS = listOf(
            "url_bar", "mozac_browser_toolbar_url_view", "location_bar_edit_text",
            "omnibartextinput", "url_field", "toolbar_edit_text",
        )

        val BROWSERS = setOf(
            "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary",
            "com.google.android.apps.chrome", "org.mozilla.firefox", "org.mozilla.firefox_beta",
            "org.mozilla.fenix", "org.mozilla.focus", "org.mozilla.klar", "com.sec.android.app.sbrowser",
            "com.brave.browser", "com.microsoft.emmx", "com.opera.browser", "com.opera.mini.native",
            "com.duckduckgo.mobile.android", "com.kiwibrowser.browser", "com.vivaldi.browser",
            "com.UCMobile.intl", "com.android.browser", "com.mi.globalbrowser", "com.huawei.browser",
            "org.chromium.webview_shell", "org.torproject.torbrowser",
        )

        /** Apps que se cierran en cuanto se abren: X / Twitter y su versión ligera. */
        val BLOCKED_APPS = setOf("com.twitter.android", "com.twitter.android.lite")

        /** Apps donde se busca pero que no son navegadores: sólo se vigila lo que se teclea. */
        val SEARCH_APPS = setOf("com.google.android.googlequicksearchbox", "com.google.android.youtube")
    }
}
