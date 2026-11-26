package com.secretsavior.guard

import android.accessibilityservice.AccessibilityService
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast
import com.secretsavior.data.Store

/**
 * El guardián. Hace tres cosas, todas locales:
 *
 *  1. Cierra las pantallas del sistema desde las que se podría apagar la
 *     protección (ficha de la app en Ajustes, desinstalar, administradores,
 *     accesibilidad, VPN, DNS privado). Instalar una actualización no cuenta:
 *     esa pantalla se deja pasar.
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
     * Los cambios de contenido sólo se piden en las pantallas del sistema: en un navegador, un
     * vídeo o un feed se producen sin parar y cada uno obliga a esa app a trabajar.
     */
    private var mode = -1
    private var foreground: String? = null

    /** Qué id tiene la barra de direcciones de cada navegador, una vez averiguado. */
    private val urlBarIds = HashMap<String, String>()
    private val urlBarMisses = HashMap<String, Long>()

    /** Se pide una vez; null si el sistema no lo da (se sondea como con pantalla encendida). */
    private val power by lazy { getSystemService(PowerManager::class.java) }

    /**
     * En vez de suscribirse a los cambios de contenido del navegador (la web los emite sin
     * parar), se relee la barra de direcciones cada [BROWSER_POLL_MS] (cada [BROWSER_IDLE_POLL_MS] con la pantalla apagada): es una sola consulta.
     * Sigue mientras el modo sea el de navegador, aunque se salte de uno a otro.
     */
    private val browserPoll = object : Runnable {
        override fun run() {
            val pkg = foreground
            if (mode != MODE_BROWSER || pkg == null || pkg !in BROWSERS) return
            // Con la pantalla apagada no llega ningún cambio de ventana y el navegador sigue
            // "delante": no vale la pena una consulta cada 1,5 s mientras la CPU esté despierta.
            val interactive = power?.isInteractive != false
            if (interactive && Store.isLocked(this@GuardService)) check(pkg)
            handler.postDelayed(this, if (interactive) BROWSER_POLL_MS else BROWSER_IDLE_POLL_MS)
        }
    }

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
        handler.removeCallbacks(browserPoll)
        handler.removeCallbacks(vendorRecheck)
        handler.removeCallbacks(settingsPass)
        hideShields()
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
        // Tras un intento, las pantallas del sistema se cierran nada más asomar.
        if (inLockout() && isSystemSurface(pkg) && type != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) {
            closeSystemScreen()
            return
        }
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            // Fuera de Ajustes las capas sobran (el teclado o la barra de notificaciones no cuentan).
            if (!isSettings(pkg) && !isNeutral(pkg)) hideShields()
            noteForeground(pkg)
            // La lista de Accesibilidad apaga el interruptor ahí mismo, sin pantalla aparte, y
            // en cuanto se apaga este servicio deja de existir: ya no puede cerrar nada después.
            // Android anuncia el título de la ventana en el propio evento (lo necesitan los
            // lectores de pantalla) antes de que la lista llegue a dibujar sus filas, así que es
            // la única señal que llega a tiempo de cerrarla antes de poder tocar nada dentro. Sin
            // excepciones aquí, ni la ventana de gracia: una vez bloqueada la app, Accesibilidad
            // no se vuelve a abrir mientras el guardián siga vivo.
            if (isSystemSurface(pkg) && isAccessibilityScreen(event)) {
                closeSystemScreen()
                return
            }
        }

        if (pkg in BLOCKED_APPS) {
            // Aunque la red falle o la app traiga contenido en caché, no se queda abierta.
            if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) block(countIt = true)
            return
        }
        if (type == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) {
            onTyped(event, pkg)
            return
        }
        if (isSettings(pkg)) {
            onSettingsEvent(event)
            return
        }
        if (!isSystemSurface(pkg) && pkg !in BROWSERS) return
        // Las apps de seguridad/optimización del fabricante (Xiaomi, Samsung...) cambian de
        // contenido sin parar mientras analizan o limpian. Se miran sólo al abrir una pantalla
        // nueva, nunca durante el trabajo: si no, se las frena justo cuando más lo necesitan.
        if (isVendorSurface(pkg) && type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        // En Xiaomi la ficha de cada app (con «Forzar detención» y «Desinstalar») es de la app de
        // Seguridad. Al abrir una de sus pantallas se tapa todo hasta haberla leído: sin esto,
        // entre que se abre y se carga su contenido daba tiempo a pulsar «Forzar detención».
        if (isVendorSurface(pkg) && type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) showCover()

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
        val active = appRoot(prefetch = false)?.packageName?.toString() ?: pkg
        if (active == packageName || isNeutral(active)) return
        foreground = active
        setMode(modeFor(active))
    }

    /**
     * Por defecto Android trae con la raíz hasta 50 nodos más, por si se piden luego. Desde
     * Android 13 se puede pedir sólo la raíz, y la app de delante trabaja menos.
     */
    /**
     * La ventana de la app que hay delante, sin contar las capas de este servicio. No vale
     * preguntar por la "ventana activa": en cuanto se toca una de nuestras capas, Android pasa a
     * considerarla a ella la activa, y el guardián creía que ya no estaba en Ajustes, quitaba
     * todas las capas y no cerraba nada. Un toque en la capa bastaba para desarmarlo. Se recorren
     * las ventanas de arriba abajo y se toma la primera de una app que no sea ésta, ni el teclado
     * ni la barra del sistema.
     */
    private fun appRoot(prefetch: Boolean): AccessibilityNodeInfo? {
        try {
            for (w in windows) {
                if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION &&
                    w.type != AccessibilityWindowInfo.TYPE_SYSTEM
                ) {
                    continue
                }
                val r = w.root ?: continue
                val p = r.packageName?.toString() ?: continue
                if (p == packageName || isNeutral(p)) continue
                return r
            }
        } catch (e: Exception) {
            // sin lista de ventanas: lo de siempre
        }
        val r = activeRoot(prefetch) ?: return null
        return if (r.packageName?.toString() == packageName) null else r
    }

    private fun activeRoot(prefetch: Boolean): AccessibilityNodeInfo? =
        if (!prefetch && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getRootInActiveWindow(0)
        } else {
            rootInActiveWindow
        }

    private fun modeFor(pkg: String) = when {
        isVendorSurface(pkg) -> MODE_VENDOR
        pkg in BROWSERS -> MODE_BROWSER
        pkg in SEARCH_APPS || pkg in FEED_APPS -> MODE_TEXT
        isSystemSurface(pkg) -> MODE_WATCH
        else -> MODE_OFF
    }

    /** La barra de notificaciones y los teclados: aparecen encima sin cambiar la app de debajo. */
    private fun isNeutral(pkg: String) = pkg == "com.android.systemui" || NEUTRAL_HINTS.any { pkg.contains(it) }

    private fun isAccessibilityScreen(event: AccessibilityEvent): Boolean {
        val title = event.text.joinToString(" ").lowercase()
        return ACCESSIBILITY_TITLES.any { title.contains(it) }
    }

    private fun setMode(newMode: Int) {
        if (mode == newMode) return
        val info = serviceInfo ?: return
        info.eventTypes = when (newMode) {
            MODE_WATCH -> EVENTS_WATCHING
            MODE_TEXT, MODE_BROWSER -> EVENTS_TYPING
            else -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        }
        serviceInfo = info
        mode = newMode
        handler.removeCallbacks(browserPoll)
        if (newMode == MODE_BROWSER) handler.postDelayed(browserPoll, BROWSER_POLL_MS)
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
        val root = appRoot(prefetch = !browser) ?: return
        if (root.packageName?.toString() != pkg) return // el evento no es de la ventana activa
        if (browser) guardBrowser(pkg, root) else guardSystemScreen(pkg, root)
    }

    // --- 0. Ajustes: capas que se tragan los toques ------------------------------------

    /**
     * Cerrar una pantalla peligrosa al verla llega tarde por definición: entre que se toca una fila
     * y que el guardián se entera pasa tiempo, y si ese toque apaga la accesibilidad, el guardián
     * muere antes de poder cerrar nada. Por eso en Ajustes no se espera a ver: las filas que
     * llevan a Accesibilidad o nombran a esta app quedan tapadas por una capa transparente que se
     * traga el toque, y la fila de abajo nunca se entera.
     *
     * Las filas se mueven (al abrir otra pantalla, al desplazar, al buscar). Mientras se mueven,
     * una capa tapa la pantalla entera, sin consultar nada, y en cuanto se asienta se recolocan
     * las capas sobre las filas y se quita la grande. Desplazar con el dedo sigue funcionando: un
     * gesto ya empezado no lo interrumpe una ventana que aparece encima.
     */
    private val shields = ArrayList<View>()
    private var cover: View? = null
    private var passQueued = false
    private var passFirstAt = 0L
    private var lastShieldToast = 0L
    private val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }

    /** La capa grande nunca se queda puesta: atascada, dejaría el teléfono sin poder tocarse. */
    private val coverTimeout = Runnable { hideCover() }

    private val settingsPass = Runnable {
        passQueued = false
        val root = appRoot(prefetch = true)
        val pkg = root?.packageName?.toString()
        if (root == null || pkg == null || !isSettings(pkg) || !Store.isLocked(this)) {
            hideShields()
            return@Runnable
        }
        // Primero se tapan las filas peligrosas (la casilla de Secret Savior en Accesibilidad,
        // la fila que lleva a Accesibilidad...) y después, si la pantalla ya es peligrosa, se
        // cierra. Las dos cosas a la vez: si el cierre tarda, el toque ya cae sobre la capa.
        val seen = scan(root)
        if (seen.ours) oursSeenAt = SystemClock.elapsedRealtime()
        placeShields(shieldRects(root, dangerButtons = seen.ours))
        hideCover()
        guardSettingsScreen(seen)
    }

    private fun isSettings(pkg: String) = pkg.contains(SETTINGS) && !isVendorSurface(pkg)

    private fun onSettingsEvent(event: AccessibilityEvent) {
        val now = SystemClock.elapsedRealtime()
        // Algo se movió (pantalla nueva, desplazamiento o, en Xiaomi, entrar en otra sección sin
        // abrir ventana): tapar todo ya, sin preguntar nada, hasta saber dónde quedan las filas.
        // Un texto que cambia (un porcentaje, un contador) no mueve filas: ése no tapa nada.
        val changes = event.contentChangeTypes
        val textOnly = event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            changes != AccessibilityEvent.CONTENT_CHANGE_TYPE_UNDEFINED &&
            changes and AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE == 0
        if (!textOnly) showCover()
        if (!passQueued) {
            passQueued = true
            passFirstAt = now
        }
        // Se espera a que deje de moverse, pero nunca más de PASS_MAX_WAIT_MS: con una animación que
        // no para, la pantalla no se puede quedar tapada para siempre.
        val delay = minOf(PASS_MS, maxOf(0L, passFirstAt + PASS_MAX_WAIT_MS - now))
        handler.removeCallbacks(settingsPass)
        handler.postDelayed(settingsPass, delay)
    }

    /** Devuelve true si la pantalla se cerró. */
    private fun guardSettingsScreen(seen: Seen): Boolean {
        // Sin administrador activo el usuario necesita llegar a la pantalla de activarlo.
        if (!Status.isAdminActive(this)) return false
        if (isStopConfirmation(seen)) {
            closeSystemScreen()
            return true
        }
        if (seen.ours) {
            // Tras pulsar «excluir de batería»/«autoinicio» en la app: dejar esas pantallas,
            // pero nunca las que ofrecen desinstalar, parar, administrar o desconectar.
            if (Store.inGrace() && !seen.dangerous) return false
            closeSystemScreen()
            return true
        }
        // Con DNS privado estricto los navegadores quedan cerrados (ver check); hay que
        // dejar llegar al editor para quitarlo, o se quedarían cerrados para siempre.
        if (seen.privateDns && !Status.isPrivateDnsStrict(this)) {
            closeSystemScreen()
            return true
        }
        return false
    }

    /** Cuándo se vio por última vez una pantalla que nombra a esta app (su ficha, su fila). */
    private var oursSeenAt = Long.MIN_VALUE / 2

    /**
     * El diálogo de confirmación de «Forzar detención» (o desinstalar, o borrar datos) no nombra a
     * la app: sólo pregunta. Si aparece poco después de una pantalla que sí la nombraba, es el de
     * esta app, y se cierra. Forzar la detención es irreversible para la protección: Android saca
     * la app de Accesibilidad, cancela sus alarmas y no le deja volver a arrancar sola.
     */
    private fun isStopConfirmation(seen: Seen): Boolean =
        !seen.ours && seen.uninstall && seen.texts <= DIALOG_MAX_TEXTS &&
            SystemClock.elapsedRealtime() - oursSeenAt < CONFIRM_WINDOW_MS

    /** Dónde están, en pantalla, las filas que hay que tapar. */
    private fun shieldRects(root: AccessibilityNodeInfo, dangerButtons: Boolean): List<Rect> {
        val words = if (dangerButtons) SHIELD_WORDS + UNINSTALL + ADMIN_OFF else SHIELD_WORDS
        val screen = Rect().also { root.getBoundsInScreen(it) }
        val maxRow = maxOf(screen.height() / 4, dp(48))
        val out = ArrayList<Rect>()
        var budget = MAX_SHIELD_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
            if (n.isEditable) continue // el cuadro de búsqueda: tapado no se podría ni corregir
            val text = n.text
            val desc = n.contentDescription
            if (text == null && desc == null) continue
            val s = "${text ?: ""} ${desc ?: ""}".lowercase()
            if (words.none { s.contains(it) }) continue
            // Se tapa la fila entera: el primer antepasado pulsable que no sea media pantalla.
            var row: AccessibilityNodeInfo = n
            var p: AccessibilityNodeInfo? = n
            repeat(6) {
                val cur = p ?: return@repeat
                if (cur.isClickable) {
                    row = cur
                    return@repeat
                }
                p = cur.parent
            }
            val r = Rect().also { row.getBoundsInScreen(it) }
            if (r.height() > maxRow) n.getBoundsInScreen(r)
            if (r.isEmpty) continue
            r.inset(-dp(6), -dp(6))
            out += r
            // La casilla de esta app (en Accesibilidad, en autoinicio...): aunque el interruptor
            // no esté dentro de la misma fila pulsable que el nombre, se tapa también el bloque
            // que contiene a los dos.
            if (OURS.any { s.contains(it) }) {
                rowOf(n)?.let { (block, sw) ->
                    val b = Rect().also { block.getBoundsInScreen(it) }
                    if (b.isEmpty || b.height() > maxRow) b.set(Rect().also { sw.getBoundsInScreen(it) })
                    if (!b.isEmpty) {
                        b.inset(-dp(8), -dp(8))
                        out += b
                    }
                }
            }
        }
        return out
    }

    private fun shieldParams(r: Rect?) = WindowManager.LayoutParams(
        r?.width() ?: WindowManager.LayoutParams.MATCH_PARENT,
        r?.height() ?: WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = r?.left ?: 0
        y = r?.top ?: 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
    }

    /** Una vista transparente que se queda con el toque; con aviso si es una fila tapada. */
    private fun newShield(tellUser: Boolean) = View(this).apply {
        setOnTouchListener { _, e ->
            if (tellUser && e.actionMasked == MotionEvent.ACTION_DOWN) {
                val now = SystemClock.elapsedRealtime()
                if (now - lastShieldToast > TOAST_MS) {
                    lastShieldToast = now
                    Toast.makeText(this@GuardService, "Secret Savior: esto no se puede abrir.", Toast.LENGTH_SHORT).show()
                }
                // Tocar lo que está tapado ya es la intención: se cierra la pantalla entera, sin
                // esperar a ver qué abre el siguiente toque.
                handler.post { closeSystemScreen() }
            }
            true
        }
    }

    private fun placeShields(rects: List<Rect>) {
        try {
            while (shields.size > rects.size) wm.removeView(shields.removeAt(shields.size - 1))
            rects.forEachIndexed { i, r ->
                if (i < shields.size) {
                    wm.updateViewLayout(shields[i], shieldParams(r))
                } else {
                    val v = newShield(tellUser = true)
                    wm.addView(v, shieldParams(r))
                    shields += v
                }
            }
        } catch (e: Exception) {
            // Si no se pudo colocar alguna, se reintenta en el próximo cambio de pantalla.
        }
    }

    private fun showCover() {
        if (cover != null) return
        try {
            val v = newShield(tellUser = false)
            wm.addView(v, shieldParams(null))
            cover = v
            handler.removeCallbacks(coverTimeout)
            handler.postDelayed(coverTimeout, COVER_MAX_MS)
        } catch (e: Exception) {
            // sin capa grande: quedan las de las filas y el cierre de siempre
        }
    }

    private fun hideCover() {
        handler.removeCallbacks(coverTimeout)
        val v = cover ?: return
        cover = null
        try {
            wm.removeView(v)
        } catch (e: Exception) {
            // ya no estaba
        }
    }

    private fun hideShields() {
        handler.removeCallbacks(settingsPass)
        passQueued = false
        hideCover()
        for (v in shields) {
            try {
                wm.removeView(v)
            } catch (e: Exception) {
                // ya no estaba
            }
        }
        shields.clear()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

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
            if (Status.isVpnPermitted(this) && scan(root).ours) closeSystemScreen()
            return
        }
        if (pkg.contains("packageinstaller")) {
            // Instalar una actualización (el APK nuevo, bajado a mano o por Play Store) pasa por
            // aquí y la pantalla nombra a la app: no es motivo para cerrarla, o nunca se podría
            // actualizar. Sólo se cierra si además ofrece algo de la lista de peligros; la de
            // desinstalar sí la lleva ("desinstalar"/"uninstall") y sigue bloqueada.
            if (scan(root).dangerous) closeSystemScreen()
            return
        }
        // Sin administrador activo el usuario necesita llegar a la pantalla de activarlo.
        if (!Status.isAdminActive(this)) return
        val seen = scan(root)
        if (seen.ours) {
            // Tras pulsar «excluir de batería»/«autoinicio» en la app: dejar esas pantallas,
            // pero nunca las que ofrecen desinstalar, parar, administrar o desconectar.
            if (Store.inGrace() && !seen.dangerous) return
            closeSystemScreen()
            return
        }
        // Con DNS privado estricto los navegadores quedan cerrados (ver check); hay que
        // dejar llegar al editor para quitarlo, o se quedarían cerrados para siempre.
        if (seen.privateDns && !Status.isPrivateDnsStrict(this)) closeSystemScreen()
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
        val root = appRoot(prefetch = true) ?: return false
        val pkg = root.packageName?.toString() ?: return false
        if (!isVendorSurface(pkg)) return true
        val seen = scan(root)
        if (Store.isLocked(this)) {
            if (seen.ours) oursSeenAt = SystemClock.elapsedRealtime()
            if (seen.autostartList || (seen.ours && seen.uninstall) || isStopConfirmation(seen)) {
                closeSystemScreen()
                return true
            }
            // Ya cargó y no es peligrosa: fuera la capa. Si nombra a la app (una lista del
            // optimizador, o su ficha a medio cargar) se sigue mirando unas veces más.
            if (seen.texts >= LOADED_TEXTS) {
                hideCover()
                return !seen.ours
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
        if (ContentRules.urlLooksBlocked(text)) block(countIt = true)
    }

    /** El filtro corre y nadie lo esquiva con DNS privado estricto. */
    private fun isProtected(): Boolean = Status.isVpnRunning() && !Status.isPrivateDnsStrict(this)

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
        /** Cuántos nodos con texto tiene: pocos = la pantalla aún carga, o es un diálogo. */
        val texts: Int,
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
        var texts = 0
        var budget = MAX_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            val text = n.text
            val desc = n.contentDescription
            if (!toggle && isSwitch(n)) toggle = true
            if (text != null || desc != null) {
                texts++
                val s = "${text ?: ""} ${desc ?: ""}".lowercase()
                if (!ours && OURS.any { s.contains(it) }) ours = true
                if (!dangerous && DANGEROUS.any { s.contains(it) }) dangerous = true
                if (!privateDns && PRIVATE_DNS_EDITOR.any { s.contains(it) }) privateDns = true
                if (!uninstall && UNINSTALL.any { s.contains(it) }) uninstall = true
                if (!title && AUTOSTART_TITLES.any { s.contains(it) }) title = true
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        return Seen(ours, dangerous, privateDns, uninstall, title && toggle, texts)
    }

    /** Hasta cuándo Ajustes y la app de Seguridad se cierran nada más abrirse. */
    private var lockoutUntil = Long.MIN_VALUE / 2

    /**
     * Cierra una pantalla del sistema por ser peligrosa, y lo toma como un intento: durante
     * [LOCKOUT_MS] (que cada intento renueva) Ajustes, el instalador y la app de Seguridad del
     * fabricante se cierran en cuanto se abren, sin esperar a leerlos. Leer una pantalla tarda, y
     * tocando muchas veces seguidas alguna vez se llegaba al botón antes que el guardián.
     */
    private fun closeSystemScreen() {
        lockoutUntil = SystemClock.elapsedRealtime() + LOCKOUT_MS
        block(countIt = false)
    }

    private fun inLockout() = SystemClock.elapsedRealtime() < lockoutUntil

    private fun block(countIt: Boolean) {
        // Atrás primero: cierra un diálogo de confirmación que esté abierto; luego al inicio.
        performGlobalAction(GLOBAL_ACTION_BACK)
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
        const val MODE_TEXT = 3
        const val MODE_BROWSER = 4
        const val BROWSER_POLL_MS = 1_500L

        /** El mismo sondeo con la pantalla apagada: sólo para enterarse de que se encendió. */
        const val BROWSER_IDLE_POLL_MS = 10_000L
        /** Tras un intento de abrir algo peligroso, cuánto tiempo se cierran Ajustes y Seguridad. */
        const val LOCKOUT_MS = 30_000L
        const val VENDOR_RETRY_MS = 150L
        const val VENDOR_ATTEMPTS = 10

        /** Con al menos tantos textos, una pantalla de la app de Seguridad ya ha cargado. */
        const val LOADED_TEXTS = 4

        /** Un diálogo de confirmación tiene pocos textos: título, mensaje y dos botones. */
        const val DIALOG_MAX_TEXTS = 12

        /** Lo que se espera, tras ver la ficha de la app, a su diálogo de confirmación. */
        const val CONFIRM_WINDOW_MS = 15_000L

        /** En la ficha del administrador del dispositivo, el botón de quitarlo. */
        val ADMIN_OFF = listOf("desactivar", "deactivate")

        /** Cómo se titula la pantalla de autoinicio en la app de seguridad del fabricante. */
        val AUTOSTART_TITLES = listOf("autoencendido", "autoinicio", "autostart", "auto-start", "inicio automático")

        /** Las clases de interruptor propias de cada fabricante (Xiaomi usa SlidingButton). */
        val SWITCH_CLASSES = listOf("switch", "slidingbutton", "toggle", "checkbox")
        const val EVENTS_WATCHING = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
            AccessibilityEvent.TYPE_VIEW_SCROLLED

        /** Sólo cambios de ventana y lo que se teclea: lo único que se usa en buscadores, feeds y navegadores. */
        const val EVENTS_TYPING = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
        val NEUTRAL_HINTS = listOf("inputmethod", "keyboard", "swiftkey", "com.baidu.input", "honeyboard")
        val NAG_STEPS_MS = longArrayOf(60_000L, 180_000L, 600_000L, 1_800_000L)
        const val TOAST_MS = 3_000L
        const val MAX_NODES = 250
        const val SETTLE_MS = 500L
        const val SCAN_WINDOW_MS = 4_000L
        const val RETRY_ID_MS = 60_000L

        /** Cómo se llama la app en pantalla, y su paquete (algunas capas del sistema lo muestran). */
        val OURS = listOf("secret savior", "com.secretsavior")

        /** Ajustes en sí (no el instalador, ni los diálogos de permisos o de VPN). */
        const val SETTINGS = "settings"

        /** Tras el último cambio de Ajustes, cuánto esperar a que la pantalla se asiente. */
        const val PASS_MS = 70L

        /** Con la pantalla cambiando sin parar, recolocar las capas al menos con esta frecuencia. */
        const val PASS_MAX_WAIT_MS = 600L
        const val MAX_SHIELD_NODES = 500

        /** Lo más que puede durar la capa grande, pase lo que pase. */
        const val COVER_MAX_MS = 1_500L

        /**
         * Las filas de Ajustes que se tapan: la que lleva a Accesibilidad (en cualquier nivel, también
         * en los resultados de la búsqueda de Ajustes) y cualquiera que nombre a esta app.
         */
        val SHIELD_WORDS = listOf("accesibilidad", "accessibility", "secret savior", "com.secretsavior")

        /** Cómo se titula la pantalla de Accesibilidad al abrirse; basta un acierto para cerrarla. */
        val ACCESSIBILITY_TITLES = listOf("accesibilidad", "accessibility")

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
