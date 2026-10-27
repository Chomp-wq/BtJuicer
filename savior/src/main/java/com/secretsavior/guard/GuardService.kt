package com.secretsavior.guard

import android.accessibilityservice.AccessibilityService
import android.os.Build
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
    private var nags = 0
    private var surfaceOpenedAt = 0L

    // Comprobación diferida: como mucho una cada SETTLE_MS mientras la pantalla cambia.
    private var deferredPkg: String? = null
    private var deferredQueued = false
    private val deferred = Runnable {
        deferredQueued = false
        deferredPkg?.let(::check)
    }

    /**
     * Android sólo genera los tipos de evento que algún servicio pide, en todas las apps.
     * Con una app no vigilada delante se piden sólo los cambios de ventana; así WhatsApp, un
     * juego o Instagram no construyen un evento por cada cosa que se mueve en pantalla.
     */
    private var mode = -1
    private var foreground: String? = null

    /** Qué id tiene la barra de direcciones de cada navegador, una vez averiguado. */
    private val urlBarIds = HashMap<String, String>()
    private val urlBarMisses = HashMap<String, Long>()

    private val tick = object : Runnable {
        override fun run() {
            patrol()
            handler.postDelayed(this, PATROL_MS)
        }
    }

    override fun onServiceConnected() {
        // No se sabe qué hay delante: se empieza mirando todo y el primer cambio de ventana afina.
        mode = -1
        foreground = null
        setMode(MODE_WATCH)
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        handler.removeCallbacks(deferred)
        handler.removeCallbacks(vendorRecheck)
        super.onDestroy()
    }

    override fun onInterrupt() = Unit

    /** Comprobación periódica: levanta el filtro y avisa si falta algo que sólo el usuario puede dar. */
    private fun patrol() {
        if (!Store.isLocked(this)) return
        val vpnOk = Watchdog.ensure(this)
        val broken = !vpnOk || !Status.isAdminActive(this)
        if (!broken) {
            nags = 0
            return
        }
        // Abrir la app encima de lo que se esté haciendo (una llamada, un vídeo) cada minuto es
        // insufferable: el primer aviso es inmediato y los siguientes se van espaciando.
        val now = SystemClock.elapsedRealtime()
        if (now - lastNag > NAG_STEPS_MS[minOf(nags, NAG_STEPS_MS.lastIndex)]) {
            lastNag = now
            nags++
            Watchdog.nag(this)
        }
    }

    /**
     * Llega un evento por cada cambio de pantalla de cualquier app. Casi todos se descartan
     * aquí, sin preguntar nada a la app: cada consulta del árbol de la ventana la contesta
     * el hilo de interfaz de esa app, y hacerlo en cada evento la ralentiza.
     */
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName) return
        val type = event.eventType
        if (!Store.isLocked(this)) {
            setMode(MODE_OFF)
            // Configuración inicial: anotar que el autoencendido de esta app está activado.
            if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && isVendorSurface(pkg)) watchVendorScreen()
            return
        }
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) noteForeground(pkg)

        if (pkg in BLOCKED_APPS) {
            // Aunque la red falle o la app traiga contenido en caché, no se queda abierta.
            if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) block(countIt = true)
            return
        }
        if (type == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) {
            onTyped(event, pkg)
            return
        }
        if (!isSystemSurface(pkg) && pkg !in BROWSERS) return
        // Las apps de seguridad/optimización del fabricante (Xiaomi, Samsung...) cambian de
        // contenido sin parar mientras analizan o limpian. Se miran sólo al abrir una pantalla
        // nueva, nunca durante el trabajo: si no, se las frena justo cuando más lo necesitan.
        if (isVendorSurface(pkg) && type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        // Cada comprobación recorre la ventana de otra app nodo a nodo, y cada nodo es una
        // consulta a esa app. En Ajustes lo peligroso aparece al abrir una pantalla; después,
        // sólo hay desplazamientos, que no hace falta mirar. Los navegadores sí cambian de
        // dirección sin abrir ventana nueva, y para ellos la comprobación es barata (una consulta).
        val now = SystemClock.elapsedRealtime()
        if (pkg !in BROWSERS) {
            if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                surfaceOpenedAt = now
            } else if (now - surfaceOpenedAt > SCAN_WINDOW_MS) {
                return
            }
        }

        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            handler.removeCallbacks(deferred)
            deferredQueued = false
            check(pkg)
        } else {
            deferredPkg = pkg
            if (!deferredQueued) {
                deferredQueued = true
                handler.postDelayed(deferred, SETTLE_MS)
            }
        }
    }

    /**
     * Qué app hay delante. El paquete del evento no basta: el teclado, una burbuja de chat o
     * un diálogo también cambian de ventana sin que cambie la app que se está usando. Se
     * pregunta qué ventana tiene el foco, y sólo cuando el paquete es nuevo.
     */
    private fun noteForeground(pkg: String) {
        if (pkg == foreground || isNeutral(pkg)) return
        val active = activeRoot(prefetch = false)?.packageName?.toString() ?: pkg
        if (active == packageName || isNeutral(active)) return
        foreground = active
        setMode(modeFor(active))
    }

    /**
     * Por defecto Android trae con la raíz hasta 50 nodos más, por si se piden luego. Desde
     * Android 13 se puede pedir sólo la raíz, y la app de delante trabaja menos.
     */
    private fun activeRoot(prefetch: Boolean): AccessibilityNodeInfo? =
        if (!prefetch && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getRootInActiveWindow(0)
        } else {
            rootInActiveWindow
        }

    private fun modeFor(pkg: String) = when {
        isVendorSurface(pkg) -> MODE_VENDOR
        pkg in BROWSERS || pkg in SEARCH_APPS || pkg in FEED_APPS || isSystemSurface(pkg) -> MODE_WATCH
        else -> MODE_OFF
    }

    /** La barra de notificaciones y los teclados: aparecen encima sin cambiar la app de debajo. */
    private fun isNeutral(pkg: String) = pkg == "com.android.systemui" || NEUTRAL_HINTS.any { pkg.contains(it) }

    private fun setMode(newMode: Int) {
        if (mode == newMode) return
        val info = serviceInfo ?: return
        info.eventTypes = when (newMode) {
            MODE_WATCH -> EVENTS_WATCHING
            else -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        }
        serviceInfo = info
        mode = newMode
    }

    private fun onTyped(event: AccessibilityEvent, pkg: String) {
        // Sólo donde se busca contenido. WhatsApp, SMS y el resto de chats quedan fuera: esto
        // protege de lo que se busca, no limita con quién se habla.
        val wide = pkg in BROWSERS || pkg in SEARCH_APPS
        if (!wide && pkg !in FEED_APPS) return
        if (event.isPassword) return
        val text = event.text.joinToString(" ")
        if (ContentRules.isExplicit(text, inBrowser = wide)) block(countIt = true)
    }

    private fun check(pkg: String) {
        val browser = pkg in BROWSERS
        if (browser && !isProtected()) {
            // Sin filtro no hay navegación. Se trae la app para que el usuario lo repare.
            block(countIt = false)
            Watchdog.nag(this)
            return
        }
        // Para el navegador basta la raíz: luego se pide la barra por su id. En Ajustes se
        // recorre la pantalla, y ahí traer nodos por adelantado ahorra viajes.
        val root = activeRoot(prefetch = !browser) ?: return
        if (root.packageName?.toString() != pkg) return // el evento no es de la ventana activa
        if (browser) guardBrowser(pkg, root) else guardSystemScreen(pkg, root)
    }

    // --- 1. Pantallas del sistema ---------------------------------------------------

    private fun guardSystemScreen(pkg: String, root: AccessibilityNodeInfo) {
        if (isVendorSurface(pkg)) {
            // Que la lista de apps del optimizador nombre a Secret Savior no es motivo para
            // cerrarlo: sólo la ficha de desinstalar/parar y la pantalla de autoencendido.
            watchVendorScreen()
            return
        }
        if (pkg.contains("vpndialogs")) {
            // Si aún no hay permiso de VPN, el diálogo es el de pedirlo y hay que dejarlo pasar.
            // Con permiso, cualquier diálogo que nombre a la app es el de "Desconectar".
            if (Status.isVpnPermitted(this) && scan(root).ours) block(countIt = false)
            return
        }
        // Sin administrador activo el usuario necesita llegar a la pantalla de activarlo.
        if (!Status.isAdminActive(this)) return
        val seen = scan(root)
        if (seen.ours) {
            // Tras pulsar «excluir de batería»/«autoinicio» en la app: dejar esas pantallas,
            // pero nunca las que ofrecen desinstalar, parar, administrar o desconectar.
            if (Store.inGrace(this) && !seen.dangerous) return
            block(countIt = false)
            return
        }
        // Con DNS privado estricto los navegadores quedan cerrados (ver check); hay que
        // dejar llegar al editor para quitarlo, o se quedarían cerrados para siempre.
        if (seen.privateDns && !Status.isPrivateDnsStrict(this)) block(countIt = false)
    }

    // --- Autoencendido (apps de seguridad del fabricante) -----------------------------

    /**
     * En Xiaomi apagar el autoencendido de una app la detiene a la fuerza y Android desactiva
     * entonces su accesibilidad: no hay forma de reencenderlo después, y tapar el interruptor
     * pierde la carrera contra quien toca rápido (la lista se reordena con una animación). Por
     * eso, con el bloqueo activo, la pantalla de autoencendido se cierra entera, y se
     * habilita antes, en la configuración inicial. Se mira sólo al abrir una pantalla nueva
     * y unas veces más mientras carga la lista: nunca mientras el optimizador trabaja.
     */
    private var vendorAttempts = 0
    private var vendorQueued = false
    private val vendorRecheck: Runnable = Runnable {
        vendorQueued = false
        if (!vendorCheck() && vendorAttempts > 0) {
            vendorAttempts--
            vendorQueued = true
            handler.postDelayed(vendorRecheck, VENDOR_RETRY_MS)
        }
    }

    private fun watchVendorScreen() {
        vendorAttempts = VENDOR_ATTEMPTS
        if (vendorCheck() || vendorQueued) return
        vendorQueued = true
        handler.postDelayed(vendorRecheck, VENDOR_RETRY_MS)
    }

    /** Devuelve true si no hace falta seguir mirando esta pantalla. */
    private fun vendorCheck(): Boolean {
        val root = activeRoot(prefetch = true) ?: return false
        val pkg = root.packageName?.toString() ?: return false
        if (!isVendorSurface(pkg)) return true
        val seen = scan(root)
        if (Store.isLocked(this)) {
            if (seen.autostartList || (seen.ours && seen.uninstall)) {
                block(countIt = false)
                return true
            }
            return false
        }
        // Aún sin bloquear: sólo observar. Si el usuario abre la pantalla de autoencendido y
        // Secret Savior está activado, se anota; es lo que exige la configuración inicial.
        if (seen.autostartList && autostartOn(root)) {
            Store.setAutostartSeen(this)
            return true
        }
        return false
    }

    private fun autostartOn(root: AccessibilityNodeInfo): Boolean =
        root.findAccessibilityNodeInfosByText("Secret Savior").any { rowOf(it)?.second?.isChecked == true }

    /** La fila (el ancestro más bajo con algún interruptor) y su interruptor. */
    private fun rowOf(label: AccessibilityNodeInfo): Pair<AccessibilityNodeInfo, AccessibilityNodeInfo>? {
        var n: AccessibilityNodeInfo? = label
        repeat(6) {
            val parent = n?.parent ?: return null
            n = parent
            firstCheckable(parent)?.let { return parent to it }
        }
        return null
    }

    private fun isSwitch(n: AccessibilityNodeInfo): Boolean =
        n.isCheckable || SWITCH_CLASSES.any { n.className?.toString()?.lowercase()?.contains(it) == true }

    private fun firstCheckable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var budget = 80
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            if (isSwitch(n)) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        return null
    }

    private fun isSystemSurface(pkg: String): Boolean =
        SYSTEM_SURFACES.any { pkg.contains(it) } || isVendorSurface(pkg)

    private fun isVendorSurface(pkg: String): Boolean =
        VENDOR_SURFACES.any { pkg.contains(it) } && SYSTEM_SURFACES.none { pkg.contains(it) }

    // --- 2. Navegadores -------------------------------------------------------------

    private fun guardBrowser(pkg: String, root: AccessibilityNodeInfo) {
        val text = urlBarText(pkg, root) ?: return
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

    /**
     * La barra de direcciones se pide por su id: una sola consulta que resuelve la propia
     * app, en vez de recorrer cientos de nodos. El id de cada navegador se averigua una vez.
     * Para uno desconocido no se recorre nada: el filtro DNS ya lo cubre.
     */
    private fun urlBarText(pkg: String, root: AccessibilityNodeInfo): String? {
        urlBarIds[pkg]?.let { return textOf(root, it) }
        val now = SystemClock.elapsedRealtime()
        if (now - (urlBarMisses[pkg] ?: Long.MIN_VALUE / 2) < RETRY_ID_MS) return null
        for (suffix in URL_BAR_IDS) {
            val id = "$pkg:id/$suffix"
            if (root.findAccessibilityNodeInfosByViewId(id).isNotEmpty()) {
                urlBarIds[pkg] = id
                return textOf(root, id)
            }
        }
        urlBarMisses[pkg] = now
        return null
    }

    private fun textOf(root: AccessibilityNodeInfo, id: String): String? =
        root.findAccessibilityNodeInfosByViewId(id).firstNotNullOfOrNull { it.text?.toString() }

    // --- utilidades -----------------------------------------------------------------

    private class Seen(
        val ours: Boolean,
        val dangerous: Boolean,
        val privateDns: Boolean,
        val uninstall: Boolean,
        /** Una lista de interruptores titulada «autoencendido»/«autoinicio». */
        val autostartList: Boolean,
    )

    /**
     * Un solo recorrido de la ventana, con tope de nodos, que mira las tres listas a la vez.
     * La búsqueda por texto del sistema sería más barata, pero las pantallas de Ajustes
     * hechas con Compose (la ficha de la app en Android 14+) no la contestan. Sólo corre en
     * apps de sistema y, como mucho, una vez cada [SETTLE_MS].
     */
    private fun scan(root: AccessibilityNodeInfo): Seen {
        var ours = false
        var dangerous = false
        var privateDns = false
        var uninstall = false
        var title = false
        var toggle = false
        var budget = MAX_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            val text = n.text
            val desc = n.contentDescription
            if (!toggle && isSwitch(n)) toggle = true
            if (text != null || desc != null) {
                val s = "${text ?: ""} ${desc ?: ""}".lowercase()
                if (!ours && OURS.any { s.contains(it) }) ours = true
                if (!dangerous && DANGEROUS.any { s.contains(it) }) dangerous = true
                if (!privateDns && PRIVATE_DNS_EDITOR.any { s.contains(it) }) privateDns = true
                if (!uninstall && UNINSTALL.any { s.contains(it) }) uninstall = true
                if (!title && AUTOSTART_TITLES.any { s.contains(it) }) title = true
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        return Seen(ours, dangerous, privateDns, uninstall, title && toggle)
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
        const val PATROL_MS = 30_000L
        const val MODE_OFF = 0
        const val MODE_WATCH = 1
        const val MODE_VENDOR = 2
        const val VENDOR_RETRY_MS = 450L
        const val VENDOR_ATTEMPTS = 6

        /** Cómo se titula la pantalla de autoinicio en la app de seguridad del fabricante. */
        val AUTOSTART_TITLES = listOf("autoencendido", "autoinicio", "autostart", "auto-start", "inicio automático")

        /** Las clases de interruptor propias de cada fabricante (Xiaomi usa SlidingButton). */
        val SWITCH_CLASSES = listOf("switch", "slidingbutton", "toggle", "checkbox")
        const val EVENTS_WATCHING = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
        val NEUTRAL_HINTS = listOf("inputmethod", "keyboard", "swiftkey", "com.baidu.input", "honeyboard")
        val NAG_STEPS_MS = longArrayOf(60_000L, 180_000L, 600_000L, 1_800_000L)
        const val TOAST_MS = 3_000L
        const val MAX_NODES = 250
        const val SETTLE_MS = 500L
        const val SCAN_WINDOW_MS = 4_000L
        const val RETRY_ID_MS = 60_000L

        /** Cómo se llama la app en pantalla, y su paquete (algunas capas del sistema lo muestran). */
        val OURS = listOf("secret savior", "com.secretsavior")

        /** Si aparece alguna de éstas junto al nombre de la app, la pantalla no es de batería. */
        val DANGEROUS = listOf(
            "desinstalar", "uninstall", "forzar", "force stop", "borrar datos", "clear data",
            "almacenamiento", "storage", "administrador", "administrator", "accesibilidad",
            "accessibility", "desconectar", "disconnect", "olvidar", "forget", "vpn",
        )

        /** Lo que sólo ofrece la ficha de una app para quitarla o pararla. */
        val UNINSTALL = listOf(
            "desinstalar", "uninstall", "forzar detención", "forzar detencion", "force stop", "borrar datos", "clear data",
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

        /** Ajustes, instalador, permisos y VPN: aquí nombrar a la app ya basta para cerrar. */
        val SYSTEM_SURFACES = listOf(
            "settings", "packageinstaller", "permissioncontroller", "vpndialogs",
        )

        /** Seguridad y optimización de cada fabricante: sólo se cierra su ficha de desinstalar. */
        val VENDOR_SURFACES = listOf("securitycenter", "safecenter", "systemmanager", "devicecare", "lool")

        /** Ids exactos (sin el paquete) de la barra de direcciones de los navegadores comunes. */
        val URL_BAR_IDS = listOf(
            "url_bar", "mozac_browser_toolbar_url_view", "location_bar_edit_text",
            "omnibarTextInput", "url_field", "search_box_text",
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

        /**
         * Telegram y Reddit: canales y comunidades con contenido para adultos. Aquí sólo
         * se vigilan las palabras sin doble sentido, no las frases de búsqueda amplias.
         */
        val FEED_APPS = setOf(
            "org.telegram.messenger", "org.telegram.messenger.web", "org.telegram.plus",
            "org.thunderdog.challegram", "nekox.messenger", "tw.nekomimi.nekogram",
            "com.reddit.frontpage", "com.rubenmayayo.reddit", "free.reddit.news",
            "com.laurencedawson.reddit_sync", "reddit.news",
        )

        /** Apps donde se busca pero que no son navegadores: sólo se vigila lo que se teclea. */
        val SEARCH_APPS = setOf("com.google.android.googlequicksearchbox", "com.google.android.youtube")
    }
}
