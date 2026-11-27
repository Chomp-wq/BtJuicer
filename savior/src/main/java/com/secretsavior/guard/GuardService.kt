package com.secretsavior.guard

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.content.res.Resources
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
import androidx.core.content.ContextCompat
import com.secretsavior.data.Store
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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
 *
 * Reconocer una pantalla no depende del idioma: ver [Labels] (palabras de 27 idiomas y las que
 * lee de los propios Ajustes), [WinKind] (clase de la ventana) y los ids de las vistas. Qué se
 * hace con lo reconocido está en [Policy], que no usa Android y se prueba aparte.
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
        guarded("comprobación diferida") { deferredPkg?.let(::check) }
    }

    /**
     * Todo lo que entra al guardián (eventos, Runnables, receptores, toques) pasa por aquí: una
     * excepción no puede llegar al sistema porque mataría el proceso, y con él el túnel VPN. Si hay
     * una capa grande puesta se vuelve a armar su tope, que es lo único que no puede quedar sin
     * programar: atascada, dejaría el teléfono sin poder tocarse.
     */
    private inline fun guarded(where: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            if (t is java.util.concurrent.CancellationException) throw t
            Safe.failed(where, t)
            safely("rearmar tope") { rearmCoverTimeout() }
        }
    }

    private fun rearmCoverTimeout() {
        if (cover == null) return
        handler.removeCallbacks(coverTimeout)
        handler.postDelayed(coverTimeout, maxOf(0L, coverDeadline - SystemClock.elapsedRealtime()))
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

    /** Hilo para lo que no debe ir en el principal: preguntar por navegadores, leer recursos. */
    private val bg: ExecutorService by lazy { Executors.newSingleThreadExecutor(NamedThreads("savior-guard-bg")) }

    /**
     * En vez de suscribirse a los cambios de contenido del navegador (la web los emite sin
     * parar), se relee la barra de direcciones cada [BROWSER_POLL_MS] (cada [BROWSER_IDLE_POLL_MS] con la pantalla apagada): es una sola consulta.
     * Sigue mientras el modo sea el de navegador, aunque se salte de uno a otro.
     */
    private val browserPoll = object : Runnable {
        override fun run() {
            // Se vuelve a programar pase lo que pase: si un fallo cortara el sondeo, el navegador
            // dejaría de vigilarse hasta el siguiente cambio de modo.
            var again = false
            var interactive = true
            guarded("sondeo del navegador") {
                val pkg = foreground
                if (mode != MODE_BROWSER || pkg == null || !isBrowser(pkg)) return@guarded
                again = true
                // Con la pantalla apagada no llega ningún cambio de ventana y el navegador sigue
                // "delante": no vale la pena una consulta cada 1,5 s mientras la CPU esté despierta.
                interactive = power?.isInteractive != false
                if (interactive && Store.isLocked(this@GuardService)) check(pkg)
            }
            if (again) handler.postDelayed(this, if (interactive) BROWSER_POLL_MS else BROWSER_IDLE_POLL_MS)
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            guarded("patrulla") { patrol() }
            handler.postDelayed(this, PATROL_MS)
        }
    }

    override fun onServiceConnected() {
        // Cada paso va aparte: que uno falle no impide arrancar la patrulla.
        safely("conexión") {
            // No se sabe qué hay delante: se empieza mirando todo y el primer cambio de ventana afina.
            mode = -1
            foreground = null
        }
        safely("etiquetas") { refreshLabels() }
        safely("navegadores") { refreshBrowsers() }
        safely("receptor de paquetes") { registerPackageReceiver() }
        safely("receptor de pantalla") { registerScreenReceiver() }
        safely("modo inicial") { setMode(MODE_WATCH) }
        safely("patrulla") {
            handler.removeCallbacks(tick)
            handler.post(tick)
        }
    }

    override fun onDestroy() {
        safely("callbacks") {
            handler.removeCallbacks(tick)
            handler.removeCallbacks(deferred)
            handler.removeCallbacks(browserPoll)
            handler.removeCallbacks(vendorRecheck)
            handler.removeCallbacks(settingsPass)
            handler.removeCallbacks(hideCoverSoon)
            handler.removeCallbacks(suiCheck)
            handler.removeCallbacks(suiPoll)
        }
        safely("capas") { hideShields() }
        safely("receptor de pantalla") {
            screenReceiver?.let { unregisterReceiver(it) } // IllegalArgumentException si ya no estaba
        }
        screenReceiver = null
        safely("receptor de paquetes") {
            pkgReceiver?.let { unregisterReceiver(it) }
        }
        pkgReceiver = null
        safely("hilo auxiliar") { bg.shutdown() }
        safely("super.onDestroy") { super.onDestroy() }
    }

    override fun onInterrupt() = Unit

    /** Cambió el idioma (u otra configuración): las palabras de pantalla son otras. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        safely("configuración") { super.onConfigurationChanged(newConfig) }
        guarded("idioma") { refreshLabels() }
    }

    // --- Idioma y navegadores -----------------------------------------------------------

    /**
     * Las palabras del idioma actual. Se construye al momento con la tabla incorporada (es poco
     * trabajo) y luego, en un hilo aparte, con lo que se lee de los recursos de Ajustes y de las
     * apps del fabricante; un fallo ahí no importa. Mientras tanto vale la primera.
     */
    @Volatile
    private var labels: Labels = Labels.build("es")
    private var labelsLocale: Locale? = null
    private var ownLabel: String = "Secret Savior"

    private fun lab(): Labels {
        val loc = resources.configuration.locales.get(0)
        if (loc != labelsLocale) refreshLabels()
        return labels
    }

    private fun refreshLabels() {
        val loc = resources.configuration.locales.get(0)
        labelsLocale = loc
        ownLabel = try {
            applicationInfo.loadLabel(packageManager).toString()
        } catch (e: Throwable) {
            "Secret Savior"
        }
        val lang = loc.language
        val script = loc.script
        val country = loc.country
        labels = Labels.build(lang, script, country, null, ownLabel)
        try {
            bg.execute {
                // Con la tabla incorporada basta si esto falla.
                safely("etiquetas del sistema") {
                    val l = Labels.build(lang, script, country, systemStrings(), ownLabel)
                    if (labelsLocale == loc) labels = l
                }
            }
        } catch (e: Throwable) {
            // servicio ya parado
        }
    }

    /**
     * Lee un texto de los recursos de otra app. En Android 11+ hace falta que el manifiesto
     * declare el paquete en `<queries>`; sin eso devuelve null y se usa sólo la tabla.
     */
    private fun systemStrings(): ResLookup {
        val cache = HashMap<String, Resources?>()
        return ResLookup { pkg, name ->
            val res = cache.getOrPut(pkg) {
                try {
                    packageManager.getResourcesForApplication(pkg)
                } catch (e: Throwable) {
                    null
                }
            }
            val id = res?.getIdentifier(name, "string", pkg) ?: 0
            if (id != 0) res?.getString(id) else null
        }
    }

    private fun isBrowser(pkg: String) = pkg in Browsers.all()

    private fun refreshBrowsers() {
        try {
            bg.execute { safely("lista de navegadores") { Browsers.refresh(applicationContext) } }
        } catch (e: Throwable) {
            // servicio ya parado
        }
    }

    private var pkgReceiver: BroadcastReceiver? = null

    /** Un navegador recién instalado o actualizado tiene que entrar en la lista sin esperar. */
    private fun registerPackageReceiver() {
        if (pkgReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                safely("receptor de paquetes") { refreshBrowsers() }
            }
        }
        val filter = IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply {
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        try {
            ContextCompat.registerReceiver(this, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            pkgReceiver = r
        } catch (e: Throwable) {
            // sin receptor: la lista se refresca al reconectar el servicio
        }
    }

    private var screenReceiver: BroadcastReceiver? = null

    /**
     * Las capas de accesibilidad se dibujan por encima de la pantalla de bloqueo y de la barra de
     * notificaciones: dejarlas puestas tapaba los dígitos del PIN y el botón de emergencia, y un
     * toque encima cerraba Ajustes con 30 s de bloqueo. Al apagar la pantalla se quitan todas
     * (la grande incluida); al desbloquear, si Ajustes sigue delante, se vuelve a tapar y a mirar.
     */
    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                guarded("receptor de pantalla") {
                    when (intent?.action) {
                        Intent.ACTION_SCREEN_OFF -> {
                            suiAbove = false
                            handler.removeCallbacks(suiCheck)
                            handler.removeCallbacks(suiPoll)
                            hideShields()
                        }
                        Intent.ACTION_USER_PRESENT -> {
                            suiAbove = false
                            val fg = foreground
                            if (fg != null && isSettings(fg) && Store.isLocked(this@GuardService)) {
                                showCover(COVER_MAX_MS, fresh = true)
                                queuePass()
                            }
                        }
                    }
                }
            }
        }
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_USER_PRESENT) }
        try {
            ContextCompat.registerReceiver(this, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            screenReceiver = r
        } catch (e: Throwable) {
            // sin receptor: quedan la comprobación de pantalla de bloqueo y la de SystemUI
        }
    }

    private val keyguard by lazy { getSystemService(KeyguardManager::class.java) }

    /** Pantalla de bloqueo (o PIN) delante: ahí no se pone ninguna capa. */
    private fun keyguardLocked(): Boolean = try {
        keyguard?.isKeyguardLocked == true
    } catch (e: Throwable) {
        false
    }

    // --- Pequeñas cachés ------------------------------------------------------------------

    private var adminAt = Long.MIN_VALUE / 2
    private var adminVal = false

    /** Preguntar al DevicePolicyManager es una llamada entre procesos: no en cada evento. */
    private fun adminActive(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - adminAt > ADMIN_CACHE_MS) {
            adminVal = Status.isAdminActive(this)
            adminAt = now
        }
        return adminVal
    }

    private var devBlockedVal = false

    /** De ida: una vez cerradas las opciones de desarrollador, ya no se miran las preferencias. */
    private fun devBlocked(): Boolean {
        if (!devBlockedVal) devBlockedVal = Store.devOptionsBlocked(this)
        return devBlockedVal
    }

    private fun graceKind(): Policy.Grace? = when (Store.grace()) {
        Store.Grace.BATTERY -> Policy.Grace.BATTERY
        Store.Grace.AUTOSTART -> Policy.Grace.AUTOSTART
        Store.Grace.NOTIFICATION_ACCESS -> Policy.Grace.NOTIFICATION_ACCESS
        Store.Grace.ALWAYS_ON_VPN -> Policy.Grace.ALWAYS_ON_VPN
        Store.Grace.AUTO_REVOKE -> Policy.Grace.AUTO_REVOKE
        null -> null
    }

    /** Comprobación periódica: levanta el filtro y avisa si falta algo que sólo el usuario puede dar. */
    private fun patrol() {
        if (!Store.isLocked(this)) return
        val vpnOk = Watchdog.ensure(this)
        val broken = !vpnOk || !adminActive()
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
        guarded("evento") { onEvent(event) }
    }

    private fun onEvent(event: AccessibilityEvent) {
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            // Sin paquete: no sirve a lo de abajo. Sólo importa si SystemUI sube o baja sobre Ajustes.
            if (Store.isLocked(this) && !suiCheckQueued) {
                suiCheckQueued = true
                handler.postDelayed(suiCheck, SUI_DEBOUNCE_MS)
            }
            return
        }
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
            if (pkg == SYSTEMUI) {
                guardSystemUi(event)
                return
            }
            // Fuera de Ajustes las capas sobran (el teclado o la barra de notificaciones no cuentan).
            if (!isSettings(pkg) && !isNeutral(pkg)) hideShields()
            noteForeground(pkg)
            if (isSystemSurface(pkg)) {
                noteWindowClass(pkg, event)
                // La lista de Accesibilidad apaga el interruptor ahí mismo, sin pantalla aparte, y
                // en cuanto se apaga este servicio deja de existir: ya no puede cerrar nada después.
                // Android anuncia el título y la clase de la ventana en el propio evento (lo necesitan
                // los lectores de pantalla) antes de que la lista llegue a dibujar sus filas, así que
                // es la única señal que llega a tiempo de cerrarla antes de poder tocar nada dentro.
                // Lo mismo con la ficha de la app (la de «Forzar detención» y «Desinstalar») si el
                // aviso ya la nombra, y con usuarios/segundo espacio y opciones de desarrollador.
                if (guardWindowEvent(pkg, event)) return
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
        val browser = isBrowser(pkg)
        if (!isSystemSurface(pkg) && !browser) return

        // Cada comprobación recorre la ventana de otra app nodo a nodo, y cada nodo es una
        // consulta a esa app. En Ajustes lo peligroso aparece al abrir una pantalla; después,
        // sólo hay desplazamientos, que no hace falta mirar. Los navegadores sí cambian de
        // dirección sin abrir ventana nueva, y para ellos la comprobación es barata (una consulta).
        val now = SystemClock.elapsedRealtime()
        if (!browser) {
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
     * Android 13+: el gestor de «aplicaciones activas» (SystemUI) lista las apps con servicios en
     * primer plano y deja pararlas con un botón; parar éste dejaría el filtro caído. Si el aviso de
     * esa ventana nombra a la app junto a una palabra de parar, se pulsa «Atrás» y nada más (no se
     * suscribe a los cambios de SystemUI: la barra de notificaciones cambia sin parar).
     */
    private fun guardSystemUi(event: AccessibilityEvent) {
        if (!adminActive()) return
        val m = windowTextMask(lab(), event)
        if (m and Concept.OURS != 0 && m and (Concept.FORCE_STOP or Concept.FORCE_STOP_WEAK) != 0) {
            performGlobalAction(GLOBAL_ACTION_BACK)
        }
    }

    /** Lo que anuncia el evento de una ventana (su título, su descripción), mirado con el autómata. */
    private fun windowTextMask(l: Labels, event: AccessibilityEvent): Int {
        var m = l.mask(event.contentDescription)
        for (t in event.text) m = m or l.mask(t)
        return m
    }

    /** Clase de la ventana de Ajustes/fabricante que hay delante, y de qué paquete es. */
    private var winKind = 0
    private var winPkg: String? = null

    /** El título anunciado de esa ventana es «autoinicio» (ver [Policy.autostartList]). */
    private var winAutoTitle = false

    /**
     * Se recuerda por ventana: el nombre de la clase no depende del idioma. Un diálogo encima (la
     * confirmación de «Forzar detención») no borra lo recordado de la pantalla de debajo.
     */
    private fun noteWindowClass(pkg: String, event: AccessibilityEvent) {
        if (pkg != winPkg) {
            winPkg = pkg
            winKind = 0
            winAutoTitle = false
        }
        val cls = event.className ?: return
        val k = WinKind.of(cls)
        if (k != 0 || !WinKind.isTransient(cls)) {
            winKind = k
            winAutoTitle = windowTextMask(lab(), event) and Concept.AUTOSTART != 0
        }
    }

    /** Devuelve true si la pantalla se cerró. */
    private fun guardWindowEvent(pkg: String, event: AccessibilityEvent): Boolean {
        val l = lab()
        val settingsLike = isSettings(pkg)
        val titleMask = windowTextMask(l, event)
        var usersTitle = false
        if (settingsLike) for (t in event.text) if (l.isUsersTitle(t)) usersTitle = true
        val close = Policy.eventClose(
            settingsLike = settingsLike,
            titleMask = titleMask,
            kind = winKind,
            usersTitle = usersTitle,
            adminActive = adminActive(),
            grace = graceKind(),
            strict = !l.known,
            devBlocked = devBlocked(),
        )
        if (close) closeSystemScreen()
        return close
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
     * La ventana de la app que hay delante, sin contar las capas de este servicio. No vale
     * preguntar por la "ventana activa": en cuanto se toca una de nuestras capas, Android pasa a
     * considerarla a ella la activa, y el guardián creía que ya no estaba en Ajustes, quitaba
     * todas las capas y no cerraba nada. Un toque en la capa bastaba para desarmarlo. Se recorren
     * las ventanas de arriba abajo y se toma la primera de una app que no sea ésta, ni el teclado
     * ni la barra del sistema.
     *
     * Por defecto Android trae con la raíz hasta 50 nodos más, por si se piden luego. Desde
     * Android 13 se elige: sólo la raíz (para mirar una barra de direcciones) o todo el árbol por
     * adelantado (para recorrer una pantalla de Ajustes, donde cada nodo suelto es un viaje).
     */
    private fun appRoot(prefetch: Boolean): AccessibilityNodeInfo? {
        val flags = if (prefetch) PREFETCH else 0
        try {
            for (w in windows) {
                if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION &&
                    w.type != AccessibilityWindowInfo.TYPE_SYSTEM
                ) {
                    continue
                }
                val r = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) w.getRoot(flags) else w.root)
                    ?: continue
                val p = r.packageName?.toString() ?: continue
                if (p == packageName || isNeutral(p)) continue
                return r
            }
        } catch (e: Throwable) {
            // sin lista de ventanas: lo de siempre
        }
        val r = activeRoot(prefetch) ?: return null
        return if (r.packageName?.toString() == packageName) null else r
    }

    private fun activeRoot(prefetch: Boolean): AccessibilityNodeInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getRootInActiveWindow(if (prefetch) PREFETCH else 0)
        } else {
            rootInActiveWindow
        }

    private fun modeFor(pkg: String) = when {
        isBrowser(pkg) -> MODE_BROWSER
        pkg in SEARCH_APPS || pkg in FEED_APPS -> MODE_TEXT
        isSystemSurface(pkg) -> MODE_WATCH
        else -> MODE_OFF
    }

    /** La barra de notificaciones y los teclados: aparecen encima sin cambiar la app de debajo. */
    private fun isNeutral(pkg: String) = pkg == SYSTEMUI || NEUTRAL_HINTS.any { pkg.contains(it) }

    private fun setMode(newMode: Int) {
        if (mode == newMode) return
        val info = serviceInfo ?: return
        info.eventTypes = when (newMode) {
            MODE_WATCH -> EVENTS_WATCHING or AccessibilityEvent.TYPE_WINDOWS_CHANGED
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
        val wide = isBrowser(pkg) || pkg in SEARCH_APPS
        if (!wide && pkg !in FEED_APPS) return
        if (event.isPassword) return
        val text = event.text.joinToString(" ")
        if (ContentRules.isExplicit(text, inBrowser = wide)) block(countIt = true)
    }

    private fun check(pkg: String) {
        val browser = isBrowser(pkg)
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
     *
     * La capa grande no se quita hasta que un recorrido vea la pantalla cargada (el de una pantalla
     * a medio cargar ve tan poco que no distingue la ficha de la app de cualquier otra): si ve
     * demasiado poco se vuelve a mirar cada [PASS_MS], y tope [COVER_MAX_MS] (más para fichas de
     * app) tras el cual la capa se va siempre.
     */
    private val shields = ArrayList<View>()
    private var cover: View? = null
    private var coverStartAt = 0L
    private var coverDeadline = 0L
    private var coverCooldownUntil = 0L
    private var passQueued = false
    private var passFirstAt = 0L
    private var lastShieldToast = 0L
    private val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }

    /** La capa grande nunca se queda puesta: atascada, dejaría el teléfono sin poder tocarse. */
    private val coverTimeout = Runnable {
        safely("tope de la capa") {
            coverCooldownUntil = SystemClock.elapsedRealtime() + COVER_COOLDOWN_MS
            hideCover()
        }
    }

    /** Tras cerrar la pantalla, la capa se queda un instante para tapar el cierre y luego se va. */
    private val hideCoverSoon = Runnable { safely("quitar capa") { hideCover() } }

    /**
     * Barra de notificaciones, ajustes rápidos o pantalla de bloqueo (SystemUI) por encima de
     * Ajustes: las capas de las filas se quitan (se tragarían toques de SystemUI) y se mira hasta
     * que se va; entonces se vuelve a tapar al instante y se hace un recorrido. [appRoot] se salta
     * las ventanas de SystemUI, así que sigue devolviendo Ajustes por debajo.
     */
    private var suiAbove = false
    private var suiSince = 0L
    private var suiCheckQueued = false

    private val suiCheck = Runnable {
        suiCheckQueued = false
        guarded("SystemUI") { recheckSystemUi() }
    }

    /** Sondeo de respaldo mientras SystemUI está encima; con tope, por si se pierde algún aviso. */
    private val suiPoll = object : Runnable {
        override fun run() {
            guarded("sondeo de SystemUI") { recheckSystemUi() }
            if (suiAbove && SystemClock.elapsedRealtime() - suiSince < SUI_POLL_MAX_MS) {
                handler.postDelayed(this, SUI_POLL_MS)
            }
        }
    }

    private fun recheckSystemUi() {
        val fg = foreground
        if (fg == null || !isSettings(fg) || !Store.isLocked(this)) {
            suiAbove = false
            return
        }
        val above = keyguardLocked() || systemUiOnTop()
        if (above) {
            if (!suiAbove) {
                suiAbove = true
                suiSince = SystemClock.elapsedRealtime()
                hideShields()
                handler.removeCallbacks(suiPoll)
                handler.postDelayed(suiPoll, SUI_POLL_MS)
            }
        } else if (suiAbove) {
            suiAbove = false
            handler.removeCallbacks(suiPoll)
            showCover(COVER_MAX_MS, fresh = true)
            queuePass()
        }
    }

    /**
     * ¿Hay una ventana grande de SystemUI (barra desplegada, ajustes rápidos, pantalla de bloqueo)
     * antes de la primera de una app? La barra de estado y la de navegación también son SYSTEM
     * de SystemUI pero finas: se descartan por su alto. Las ventanas vienen de arriba abajo.
     */
    private fun systemUiOnTop(): Boolean {
        try {
            val minH = Resources.getSystem().displayMetrics.heightPixels / SUI_MIN_HEIGHT_DIV
            val b = Rect()
            for (w in windows) {
                when (w.type) {
                    AccessibilityWindowInfo.TYPE_SYSTEM -> {
                        w.getBoundsInScreen(b)
                        if (b.height() < minH) continue
                        if (w.root?.packageName?.toString() == SYSTEMUI) return true
                    }
                    AccessibilityWindowInfo.TYPE_APPLICATION -> {
                        val p = w.root?.packageName?.toString() ?: continue
                        if (p == packageName || isNeutral(p)) continue
                        return false // la primera app de verdad: nada la tapa
                    }
                    else -> Unit
                }
            }
        } catch (e: Throwable) {
            // sin lista de ventanas: se queda como estaba
        }
        return false
    }

    /** Pide un recorrido de Ajustes en cuanto la pantalla se asiente (como tras un cambio de pantalla). */
    private fun queuePass() {
        val now = SystemClock.elapsedRealtime()
        if (!passQueued) {
            passQueued = true
            passFirstAt = now
        }
        val delay = minOf(PASS_MS, maxOf(0L, passFirstAt + PASS_MAX_WAIT_MS - now))
        handler.removeCallbacks(settingsPass)
        handler.postDelayed(settingsPass, delay)
    }

    private val settingsPass: Runnable = Runnable {
        passQueued = false
        try {
            settingsPassBody()
        } catch (t: Throwable) {
            // Estado seguro: sin capas puestas, ni de filas ni la grande (y sin su tope pendiente).
            Safe.failed("recorrido de Ajustes", t)
            safely("quitar capas") { hideShields() }
        }
    }

    private fun settingsPassBody() {
        val root = appRoot(prefetch = true)
        val pkg = root?.packageName?.toString()
        if (root == null || pkg == null || !isSettings(pkg) || !Store.isLocked(this)) {
            hideShields()
            return
        }
        // Con la pantalla de bloqueo o SystemUI delante no se pone nada: ahí se teclea el PIN.
        if (suiAbove || keyguardLocked()) {
            hideShields()
            return
        }
        // Un solo recorrido de la pantalla lo mira todo: qué conceptos hay (para decidir) y qué
        // nodos son candidatos a taparse (para colocar las capas). Primero se tapan las filas
        // peligrosas y después, si la pantalla ya es peligrosa, se cierra: si el cierre tarda, el
        // toque ya cae sobre la capa.
        val p = analyze(root, collect = true)
        val now = SystemClock.elapsedRealtime()
        if (p.mask and Concept.OURS != 0) oursSeenAt = now
        val v = Policy.decide(policyInput(pkg, p))
        // Si colocar las capas falla se quitan las de las filas, pero el cierre sigue su curso.
        try {
            placeShields(shieldRects(root, p, v))
        } catch (t: Throwable) {
            Safe.failed("capas de filas", t)
            safely("quitar capas de filas") { removeRowShields() }
        }
        if (v.close) {
            // Pase lo que pase con el cierre, la capa grande se programa para irse.
            safely("cierre") { closeSystemScreen() }
            handler.removeCallbacks(hideCoverSoon)
            handler.postDelayed(hideCoverSoon, COVER_AFTER_CLOSE_MS)
            return
        }
        if (v.keepCover && cover != null && now < coverDeadline) {
            passQueued = true
            handler.postDelayed(settingsPass, PASS_MS)
            return
        }
        hideCover()
    }

    /**
     * Ajustes y la app de Seguridad del fabricante: las dos se vigilan igual, con capas y cambios de
     * contenido. En Xiaomi la ficha de cada app es de Seguridad, y se abre a menudo sin ventana
     * nueva: mirándola sólo al abrirse ventanas, el guardián nunca se enteraba.
     */
    private fun isSettings(pkg: String) = pkg.contains(SETTINGS) || isVendorSurface(pkg)

    private fun onSettingsEvent(event: AccessibilityEvent) {
        // Si se perdió el aviso de que SystemUI se fue, un evento de Ajustes lo corrige ya.
        if (suiAbove) recheckSystemUi()
        // Algo se movió (pantalla nueva, desplazamiento o, en Xiaomi, entrar en otra sección sin
        // abrir ventana): tapar todo ya, sin preguntar nada, hasta saber dónde quedan las filas.
        // Un texto que cambia (un porcentaje, un contador) no mueve filas: ése no tapa nada.
        val changes = event.contentChangeTypes
        val textOnly = event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            changes != AccessibilityEvent.CONTENT_CHANGE_TYPE_UNDEFINED &&
            changes and AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE == 0
        if (!textOnly) {
            showCover(
                if (winKind and WinKind.APP_DETAILS != 0) COVER_APP_DETAILS_MS else COVER_MAX_MS,
                fresh = event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            )
        }
        // Se espera a que deje de moverse, pero nunca más de PASS_MAX_WAIT_MS: con una animación que
        // no para, la pantalla no se puede quedar tapada para siempre.
        queuePass()
    }

    private fun surfaceOf(pkg: String) = when {
        pkg.contains("vpndialogs") -> Policy.Surface.VPN_DIALOGS
        pkg.contains("packageinstaller") -> Policy.Surface.INSTALLER
        isVendorSurface(pkg) -> Policy.Surface.VENDOR
        pkg.contains(SETTINGS) -> Policy.Surface.SETTINGS
        else -> Policy.Surface.PERMISSIONS
    }

    private fun policyInput(pkg: String, p: Pass): Policy.Input {
        val surface = surfaceOf(pkg)
        val kind = if (pkg == winPkg) winKind else 0
        return Policy.Input(
            surface = surface,
            mask = p.mask,
            kind = kind,
            dangerId = p.dangerId,
            texts = p.texts,
            // Sólo por la clase o el título de la ventana: la ficha de cualquier app en MIUI también
            // tiene una fila «Inicio automático» con interruptor y no es la lista.
            autostartList = Policy.autostartList(kind, if (pkg == winPkg && winAutoTitle) Concept.AUTOSTART else 0),
            strict = !lab().known,
            grace = graceKind(),
            adminActive = adminActive(),
            privateDnsStrict = p.mask and Concept.PRIVATE_DNS_EDITOR != 0 && Status.isPrivateDnsStrict(this),
            vpnPermitted = surface == Policy.Surface.VPN_DIALOGS && Status.isVpnPermitted(this),
            devBlocked = devBlocked(),
            recentOurs = SystemClock.elapsedRealtime() - oursSeenAt < CONFIRM_WINDOW_MS,
            secondSpaceSurface = pkg.contains("securitycore"),
        )
    }

    /**
     * Cuándo se vio por última vez una pantalla que nombra a esta app (su ficha, su fila). El
     * diálogo de confirmación de «Forzar detención» (o desinstalar, o borrar datos) no nombra a la
     * app: sólo pregunta. Si aparece poco después de una pantalla que sí la nombraba, es el de
     * esta app, y se cierra. Forzar la detención es irreversible para la protección: Android saca
     * la app de Accesibilidad, cancela sus alarmas y no le deja volver a arrancar sola.
     */
    private var oursSeenAt = Long.MIN_VALUE / 2

    /** Dónde están, en pantalla, las filas que hay que tapar. */
    private fun shieldRects(root: AccessibilityNodeInfo, p: Pass, v: Policy.Verdict): List<Rect> {
        if (p.cands.isEmpty()) return emptyList()
        val screen = Rect().also { root.getBoundsInScreen(it) }
        val maxRow = maxOf(screen.height() / 4, dp(48))
        val out = ArrayList<Rect>()
        for (c in p.cands) {
            val hit = c.mask and v.shield != 0 ||
                (v.shieldOurs && c.mask and Concept.OURS != 0) ||
                (v.shieldIds && c.mask and Concept.DANGER_ID != 0)
            if (!hit) continue
            val n = c.node
            // Se tapa la fila entera: el primer antepasado pulsable que no sea media pantalla.
            var row: AccessibilityNodeInfo = n
            var anc: AccessibilityNodeInfo? = n
            repeat(6) {
                val cur = anc ?: return@repeat
                if (cur.isClickable) {
                    row = cur
                    return@repeat
                }
                anc = cur.parent
            }
            val r = Rect().also { row.getBoundsInScreen(it) }
            if (r.height() > maxRow) n.getBoundsInScreen(r)
            if (r.isEmpty) continue
            r.inset(-dp(6), -dp(6))
            if (out.none { it == r }) out += r
            // La casilla de esta app (en Accesibilidad, en autoinicio...): aunque el interruptor
            // no esté dentro de la misma fila pulsable que el nombre, se tapa también el bloque
            // que contiene a los dos.
            if (v.shieldOurs && c.mask and Concept.OURS != 0) {
                rowOf(n)?.let { (block, sw) ->
                    val b = Rect().also { block.getBoundsInScreen(it) }
                    if (b.isEmpty || b.height() > maxRow) b.set(Rect().also { sw.getBoundsInScreen(it) })
                    if (!b.isEmpty) {
                        b.inset(-dp(8), -dp(8))
                        if (out.none { it == b }) out += b
                    }
                }
            }
            if (out.size >= MAX_SHIELDS) break
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
        // ALWAYS es de Android 11; en 9 y 10 ese valor no existe y puede rechazarse (la capa no se
        // pondría): ahí SHORT_EDGES, que también cubre la muesca en vertical.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    /** Una vista transparente que se queda con el toque; con aviso si es una fila tapada. */
    private fun newShield(tellUser: Boolean) = View(this).apply {
        setOnTouchListener { _, e ->
            if (tellUser && e.actionMasked == MotionEvent.ACTION_DOWN) {
                // Sin el aviso también se cierra, y sin el cierre la capa sigue tragándose el toque.
                safely("aviso de capa") {
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastShieldToast > TOAST_MS) {
                        lastShieldToast = now
                        Toast.makeText(this@GuardService, "Secret Savior: esto no se puede abrir.", Toast.LENGTH_SHORT).show()
                    }
                }
                // Tocar lo que está tapado ya es la intención: se cierra la pantalla entera, sin
                // esperar a ver qué abre el siguiente toque.
                safely("cierre por toque") { handler.post { guarded("cierre por toque") { closeSystemScreen() } } }
            }
            true
        }
    }

    private fun placeShields(rects: List<Rect>) {
        try {
            while (shields.size > rects.size) removeOverlay(shields.removeAt(shields.size - 1))
            rects.forEachIndexed { i, r ->
                if (i < shields.size) {
                    wm.updateViewLayout(shields[i], shieldParams(r))
                } else {
                    val v = newShield(tellUser = true)
                    wm.addView(v, shieldParams(r))
                    shields += v
                }
            }
        } catch (t: Throwable) {
            // Estado seguro: ninguna capa a medias. Se reintenta en el próximo cambio de pantalla.
            Safe.failed("colocar capas", t)
            safely("quitar capas de filas") { removeRowShields() }
        }
    }

    /** Quitar una vista que ya no esté (o que la ROM no deje quitar) no puede lanzar. */
    private fun removeOverlay(v: View) {
        safely("quitar capa") { wm.removeView(v) }
    }

    private fun removeRowShields() {
        val all = ArrayList(shields)
        shields.clear()
        for (v in all) removeOverlay(v)
    }

    /**
     * [fresh]: una ventana nueva. Pasado el tope de la capa, los cambios de contenido de la misma
     * pantalla no la vuelven a poner enseguida (una animación sin fin la dejaría puesta siempre).
     */
    private fun showCover(maxMs: Long, fresh: Boolean) {
        if (suiAbove || keyguardLocked()) return
        val now = SystemClock.elapsedRealtime()
        if (cover != null) {
            // Sólo se alarga el tope hasta el que corresponde a la clase de pantalla, contado
            // desde que se puso la capa: nunca se renueva con cada evento.
            if (coverStartAt + maxMs > coverDeadline) {
                coverDeadline = coverStartAt + maxMs
                handler.removeCallbacks(coverTimeout)
                handler.postDelayed(coverTimeout, maxOf(0L, coverDeadline - now))
            }
            return
        }
        if (!fresh && now < coverCooldownUntil) return
        var v: View? = null
        try {
            v = newShield(tellUser = false)
            wm.addView(v, shieldParams(null))
            // El tope se programa antes que nada más: lo que venga después no puede dejarla sin él.
            cover = v
            coverStartAt = now
            coverDeadline = now + maxMs
            handler.removeCallbacks(coverTimeout)
            handler.postDelayed(coverTimeout, maxMs)
        } catch (t: Throwable) {
            // sin capa grande: quedan las de las filas y el cierre de siempre
            Safe.failed("capa grande", t)
            safely("quitar capa grande") { hideCover() }
            v?.let { if (it !== cover) removeOverlay(it) }
        }
    }

    private fun hideCover() {
        handler.removeCallbacks(coverTimeout)
        val v = cover ?: return
        cover = null
        removeOverlay(v) // si ya no estaba, no importa
    }

    private fun hideShields() {
        handler.removeCallbacks(settingsPass)
        passQueued = false
        safely("quitar capa grande") { hideCover() }
        removeRowShields()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    // --- 1. Pantallas del sistema ---------------------------------------------------

    /** Instalador, diálogos de VPN y permisos: sin capas, sólo se lee y se cierra. */
    private fun guardSystemScreen(pkg: String, root: AccessibilityNodeInfo) {
        if (isSettings(pkg)) return // Ajustes y el fabricante los lleva settingsPass
        val p = analyze(root, collect = false)
        val v = Policy.decide(policyInput(pkg, p))
        if (v.close) closeSystemScreen()
    }

    // --- Autoencendido (apps de seguridad del fabricante) -----------------------------

    /**
     * En Xiaomi apagar el autoencendido de una app la detiene a la fuerza y Android desactiva
     * entonces su accesibilidad: no hay forma de reencenderlo después, y tapar el interruptor
     * pierde la carrera contra quien toca rápido (la lista se reordena con una animación). Por
     * eso, con el bloqueo activo, la pantalla de autoencendido se cierra entera (lo decide
     * [Policy]), y se habilita antes, en la configuración inicial. Aquí, sin bloqueo, sólo se
     * observa si el usuario la abre y Secret Savior está activado: es lo que exige la
     * configuración inicial. Se mira al abrir una pantalla nueva y unas veces más mientras carga.
     */
    private var vendorAttempts = 0
    private var vendorQueued = false
    private val vendorRecheck: Runnable = Runnable {
        vendorQueued = false
        guarded("autoencendido") {
            if (!vendorCheck() && vendorAttempts > 0) {
                vendorAttempts--
                vendorQueued = true
                handler.postDelayed(vendorRecheck, VENDOR_RETRY_MS)
            }
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
        if (Store.isLocked(this)) return true // de aquí en adelante lo lleva settingsPass
        val p = analyze(root, collect = false)
        val kind = if (pkg == winPkg) winKind else 0
        val autostartList = (p.mask and Concept.AUTOSTART != 0 && p.toggle) || kind and WinKind.AUTOSTART != 0
        if (autostartList && autostartOn(root)) {
            Store.setAutostartSeen(this)
            return true
        }
        return false
    }

    private fun autostartOn(root: AccessibilityNodeInfo): Boolean =
        root.findAccessibilityNodeInfosByText(ownLabel).any { rowOf(it)?.second?.isChecked == true }

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

    private fun isSwitch(n: AccessibilityNodeInfo): Boolean {
        if (n.isCheckable) return true
        val cls = n.className ?: return false
        for (s in SWITCH_CLASSES) if (Labels.containsIc(cls, s)) return true
        return false
    }

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
     * Para uno desconocido, cuyo id no está en la lista, se hace una búsqueda acotada
     * (≤ [GENERIC_URL_NODES] nodos, como mucho una vez cada [RETRY_ID_MS]).
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
        genericUrlBarId(root)?.let { id ->
            urlBarIds[pkg] = id
            return textOf(root, id)
        }
        urlBarMisses[pkg] = now
        return null
    }

    /** El primer nodo con texto (o editable) cuyo id parece de barra de direcciones. */
    private fun genericUrlBarId(root: AccessibilityNodeInfo): String? {
        var budget = GENERIC_URL_NODES
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            val id = n.viewIdResourceName
            if (id != null && UrlBar.isUrlBarId(id) && (n.isEditable || !n.text.isNullOrEmpty())) return id
            for (i in n.childCount - 1 downTo 0) n.getChild(i)?.let(stack::add)
        }
        return null
    }

    private fun textOf(root: AccessibilityNodeInfo, id: String): String? =
        root.findAccessibilityNodeInfosByViewId(id).firstNotNullOfOrNull { it.text?.toString() }

    // --- utilidades -----------------------------------------------------------------

    /** Un nodo que puede tener que taparse, con sus conceptos. */
    private class Cand(val node: AccessibilityNodeInfo, val mask: Int)

    /** Lo que se vio en una pantalla de una sola pasada. Se reutiliza: no reserva por recorrido. */
    private class Pass {
        var mask = 0
        var dangerId = false
        var toggle = false

        /** Cuántos nodos con texto tiene: pocos = la pantalla aún carga, o es un diálogo. */
        var texts = 0
        val cands = ArrayList<Cand>()

        fun reset() {
            mask = 0
            dangerId = false
            toggle = false
            texts = 0
            cands.clear()
        }
    }

    private val pass = Pass()
    private val walk = ArrayDeque<AccessibilityNodeInfo>()

    /**
     * Un solo recorrido de la ventana, con tope de nodos. Antes eran dos (uno para decidir y otro
     * para colocar las capas) y cada `getChild` es un viaje a Ajustes. El autómata mira el texto y
     * la descripción por separado: no se junta ni se pasa a minúsculas ninguna cadena por nodo.
     * La búsqueda por texto del sistema sería más barata, pero las pantallas de Ajustes hechas con
     * Compose (la ficha de la app en Android 14+) no la contestan. Sólo corre en apps de sistema
     * y, como mucho, una vez cada [SETTLE_MS] (o cada [PASS_MS] mientras carga).
     */
    private fun analyze(root: AccessibilityNodeInfo, collect: Boolean): Pass {
        val p = pass
        p.reset()
        val l = lab()
        var budget = if (collect) MAX_PASS_NODES else MAX_NODES
        val stack = walk
        stack.clear()
        stack.add(root)
        while (stack.isNotEmpty() && budget-- > 0) {
            val n = stack.removeLast()
            if (!p.toggle && isSwitch(n)) p.toggle = true
            val dangerId = Labels.isDangerId(n.viewIdResourceName)
            if (dangerId) p.dangerId = true
            val text = n.text
            val desc = n.contentDescription
            var m = 0
            if (text != null || desc != null) {
                p.texts++
                m = l.mask(text) or l.mask(desc)
                p.mask = p.mask or m
            }
            if (collect && p.cands.size < MAX_CANDS) {
                // El cuadro de búsqueda no se tapa: tapado no se podría ni corregir.
                val cm = if (dangerId) m or Concept.DANGER_ID else m
                if (cm and SHIELDABLE != 0 && !n.isEditable) p.cands += Cand(n, cm)
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let(stack::add)
        }
        stack.clear()
        return p
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
        // Cada paso va aparte: que falle el aviso no impide mandar al inicio, que es lo que importa.
        safely("atrás") { performGlobalAction(GLOBAL_ACTION_BACK) }
        safely("inicio") { performGlobalAction(GLOBAL_ACTION_HOME) }
        val now = SystemClock.elapsedRealtime()
        if (now - lastBlock > TOAST_MS) {
            safely("aviso de bloqueo") {
                Toast.makeText(this, "Secret Savior: bloqueado. Respira, esto pasa.", Toast.LENGTH_SHORT).show()
            }
            if (countIt) safely("contador") { Store.countBlock(this) }
        }
        lastBlock = now
    }

    private companion object {
        const val SYSTEMUI = "com.android.systemui"
        const val PATROL_MS = 30_000L
        const val MODE_OFF = 0
        const val MODE_WATCH = 1
        const val MODE_TEXT = 3
        const val MODE_BROWSER = 4
        const val BROWSER_POLL_MS = 1_500L

        /** El mismo sondeo con la pantalla apagada: sólo para enterarse de que se encendió. */
        const val BROWSER_IDLE_POLL_MS = 10_000L

        /** Tras un intento de abrir algo peligroso, cuánto tiempo se cierran Ajustes y Seguridad. */
        const val LOCKOUT_MS = 30_000L
        const val VENDOR_RETRY_MS = 150L

        /** SystemUI encima de Ajustes: espera tras un aviso de ventanas, sondeo de respaldo y su tope. */
        const val SUI_DEBOUNCE_MS = 60L
        const val SUI_POLL_MS = 250L
        const val SUI_POLL_MAX_MS = 120_000L

        /** Una ventana de SystemUI con menos de 1/3 del alto de la pantalla es una barra, no la cortina. */
        const val SUI_MIN_HEIGHT_DIV = 3
        const val VENDOR_ATTEMPTS = 10

        /** Lo que se espera, tras ver la ficha de la app, a su diálogo de confirmación. */
        const val CONFIRM_WINDOW_MS = 15_000L

        /** Cuánto vale la respuesta de «¿es administradora?» (una llamada entre procesos). */
        const val ADMIN_CACHE_MS = 2_000L

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

        /** Con capas, el recorrido es uno solo y cubre lo que antes cubrían dos (250 + 500). */
        const val MAX_PASS_NODES = 500
        const val MAX_CANDS = 80
        const val MAX_SHIELDS = 40
        const val GENERIC_URL_NODES = 150
        const val SETTLE_MS = 500L
        const val SCAN_WINDOW_MS = 4_000L
        const val RETRY_ID_MS = 60_000L

        /** Android 13+: traer el árbol entero por adelantado (menos viajes que nodo a nodo). */
        val PREFETCH = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            AccessibilityNodeInfo.FLAG_PREFETCH_DESCENDANTS_HYBRID
        } else {
            0
        }

        /** Ajustes en sí (no el instalador, ni los diálogos de permisos o de VPN). */
        const val SETTINGS = "settings"

        /** Tras el último cambio de Ajustes, cuánto esperar a que la pantalla se asiente. */
        const val PASS_MS = 70L

        /** Con la pantalla cambiando sin parar, recolocar las capas al menos con esta frecuencia. */
        const val PASS_MAX_WAIT_MS = 600L

        /** Lo más que puede durar la capa grande, pase lo que pase (más en la ficha de una app). */
        const val COVER_MAX_MS = 1_500L
        const val COVER_APP_DETAILS_MS = 2_500L

        /** Tras agotar el tope, los cambios de contenido de la misma pantalla no la vuelven a poner. */
        const val COVER_COOLDOWN_MS = 1_500L

        /** Tras cerrar una pantalla, cuánto sigue la capa tapando el cierre. */
        const val COVER_AFTER_CLOSE_MS = 400L

        /** Los conceptos cuyas filas pueden llegar a taparse: lo demás no se guarda como candidato. */
        const val SHIELDABLE = Concept.ACCESSIBILITY or Concept.USERS_SECOND_SPACE or Concept.DEVELOPER_OPTIONS or
            Concept.BUILD_NUMBER or Concept.OURS or Concept.STRONG or Concept.WEAK or
            Concept.DEACTIVATE_ADMIN or Concept.DEACTIVATE_ADMIN_WEAK or Concept.VPN_DISCONNECT_FORGET or
            Concept.LOCKDOWN_TOGGLE or Concept.DANGER_ID

        /** Ajustes, instalador, permisos y VPN: aquí nombrar a la app ya basta para cerrar. */
        val SYSTEM_SURFACES = listOf(
            "settings", "packageinstaller", "permissioncontroller", "vpndialogs",
        )

        /**
         * Seguridad y optimización de cada fabricante: sólo se cierra su ficha de desinstalar.
         * powerkeeper = batería por app de Xiaomi; securitycore = Segundo espacio de Xiaomi.
         */
        val VENDOR_SURFACES = listOf(
            "securitycenter", "safecenter", "systemmanager", "devicecare", "lool", "powerkeeper", "securitycore",
        )

        /** Ids exactos (sin el paquete) de la barra de direcciones de los navegadores comunes. */
        val URL_BAR_IDS = listOf(
            "url_bar", "mozac_browser_toolbar_url_view", "location_bar_edit_text",
            "omnibarTextInput", "url_field", "search_box_text",
        )

        /**
         * Apps que se cierran en cuanto se abren. X / Twitter y su versión ligera por su contenido.
         * Las demás esquivan el filtro DNS por diseño: Tor Browser (release y alpha) y Orbot (la
         * VPN de Tor) mandan el tráfico por una red que resuelve los nombres fuera del teléfono, y
         * Aloha trae una VPN propia. Sólo van paquetes verificados; los que no, fuera.
         */
        val BLOCKED_APPS = setOf(
            "com.twitter.android", "com.twitter.android.lite",
            "org.torproject.torbrowser", "org.torproject.torbrowser_alpha", "org.torproject.android",
            "com.aloha.browser",
        )

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
