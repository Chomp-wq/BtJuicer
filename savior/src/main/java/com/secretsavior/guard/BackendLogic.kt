package com.secretsavior.guard

/**
 * Lógica pura del backend (sin Android) para poder probarla con JUnit a secas.
 * Las usan [SelfHeal], [Owner] y [Notice].
 */

/** Mezcla de `enabled_accessibility_services`: añade la nuestra sin tocar las del usuario. */
object A11yList {

    /**
     * Android guarda los componentes a veces como `pkg/pkg.Clase` y a veces como `pkg/.Clase`;
     * se comparan en forma larga y sin mayúsculas para no duplicar la nuestra.
     */
    fun canon(item: String): String {
        val s = item.trim()
        val slash = s.indexOf('/')
        if (slash <= 0) return s.lowercase()
        val pkg = s.substring(0, slash)
        val cls = s.substring(slash + 1)
        val full = if (cls.startsWith(".")) pkg + cls else cls
        return "$pkg/$full".lowercase()
    }

    fun contains(current: String?, me: String): Boolean {
        val m = canon(me)
        return current.orEmpty().split(':').any { it.isNotBlank() && canon(it) == m }
    }

    /** Devuelve [current] intacta si ya está (así no se escribe de más); si no, la lista + [me]. */
    fun merge(current: String?, me: String): String {
        val cur = current.orEmpty()
        if (contains(cur, me)) return cur
        val parts = cur.split(':').map { it.trim() }.filter { it.isNotEmpty() }
        return (parts + me).joinToString(":")
    }
}

/** Qué restricciones de usuario pone la propietaria del dispositivo, según el nivel de API. */
object OwnerPolicy {

    // Literales de UserManager.DISALLOW_*: así esto no depende de Android.
    const val SAFE_BOOT = "no_safe_boot"
    const val FACTORY_RESET = "no_factory_reset"
    const val ADD_USER = "no_add_user"
    const val ADD_MANAGED_PROFILE = "no_add_managed_profile"
    const val USER_SWITCH = "no_user_switch"
    const val CONFIG_VPN = "no_config_vpn"
    const val CONFIG_PRIVATE_DNS = "no_config_private_dns"
    const val DEBUGGING = "no_debugging_features"

    /**
     * No van `DISALLOW_APPS_CONTROL` (bloquearía todas las apps) ni
     * `DISALLOW_INSTALL_UNKNOWN_SOURCES` (las actualizaciones se instalan a mano).
     */
    fun restrictions(sdk: Int, adbBlocked: Boolean): List<String> = buildList {
        add(SAFE_BOOT)
        add(FACTORY_RESET)
        add(ADD_USER)
        if (sdk >= 26) add(ADD_MANAGED_PROFILE)
        if (sdk >= 28) add(USER_SWITCH)
        add(CONFIG_VPN)
        if (sdk >= 29) add(CONFIG_PRIVATE_DNS)
        if (adbBlocked) add(DEBUGGING)
    }

    /** Apps cerradas al abrir (ver GuardService.BLOCKED_APPS); aquí además se ocultan. */
    val HIDDEN_APPS = listOf("com.twitter.android", "com.twitter.android.lite")
}

/** Cuándo cerrar los navegadores si la protección está rota, y cuándo devolverlos. */
object SuspendGate {

    const val THRESHOLD_MS = 20_000L
    const val NOT_BROKEN = Long.MIN_VALUE

    enum class Action { NONE, SUSPEND, LIFT }

    data class Decision(val brokenSince: Long, val action: Action)

    /**
     * [brokenSince]: desde cuándo (reloj monótono) está rota sin interrupción, o [NOT_BROKEN].
     * [suspended]: hay navegadores suspendidos por nosotros. La salida segura manda: si la
     * protección está bien, o ya no somos propietaria con bloqueo, se levanta siempre.
     */
    fun decide(eligible: Boolean, broken: Boolean, brokenSince: Long, now: Long, suspended: Boolean): Decision {
        if (!eligible || !broken) {
            return Decision(NOT_BROKEN, if (suspended) Action.LIFT else Action.NONE)
        }
        val since = if (brokenSince == NOT_BROKEN) now else brokenSince
        val act = if (!suspended && now - since >= THRESHOLD_MS) Action.SUSPEND else Action.NONE
        return Decision(since, act)
    }

    /** Navegadores instalados, sin los que no se pueden tocar (lanzador, teléfono, Ajustes...). */
    fun targets(browsers: Set<String>, protectedPkgs: Set<String>, installed: (String) -> Boolean): List<String> =
        browsers.filter { it !in protectedPkgs && installed(it) }.sorted()
}

/** Deja pasar una vez cada [gapMs]. El reloj lo pone quien llama. */
class Throttle(private val gapMs: Long) {
    private var last = 0L
    private var any = false

    @Synchronized
    fun tryPass(now: Long): Boolean {
        if (any && now - last in 0 until gapMs) return false
        any = true
        last = now
        return true
    }
}
