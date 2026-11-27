package com.secretsavior.vpn

/**
 * Cuál es la red real por defecto (la que usaría el teléfono sin nuestra VPN), y avisa SÓLO cuando
 * cambia de verdad. Sin Android: [T] es el identificador de red (en Android, `Network`).
 *
 * Por qué: con «datos móviles siempre activos» una red móvil de fondo aparece y desaparece mientras
 * el teléfono está en Wi-Fi. Reaccionar a cada red (olvidar caducadas, reenviar todo) en cada parpadeo
 * es trabajo inútil y tira la caché. Sólo importa a qué red salen de verdad las consultas.
 *
 * Dos modos: Android 12+ dice él mismo cuál es la mejor ([onBest], [onBestLost]); antes se deduce de
 * las redes disponibles con [rank] ([onAvailable], [onCaps], [onLost]).
 */
class DefaultNetworkTracker<T : Any>(private val onChange: (T?) -> Unit) {

    enum class Transport { ETHERNET, WIFI, CELLULAR, OTHER }

    class Caps(val validated: Boolean, val transport: Transport)

    private val known = LinkedHashMap<T, Caps>()

    @Volatile
    var current: T? = null
        private set

    /** Fija la red de partida (al arrancar) sin avisar: no es un cambio. */
    @Synchronized
    fun seed(initial: Map<T, Caps>) {
        known.clear()
        known.putAll(initial)
        current = pick()
    }

    @Synchronized
    fun onAvailable(n: T, caps: Caps?) {
        known[n] = caps ?: known[n] ?: Caps(false, Transport.OTHER)
        recompute()
    }

    @Synchronized
    fun onCaps(n: T, caps: Caps) {
        if (n !in known) return
        known[n] = caps
        recompute()
    }

    @Synchronized
    fun onLost(n: T) {
        if (known.remove(n) == null) return
        recompute()
    }

    /** Android 12+: ésta es ahora la mejor. */
    @Synchronized
    fun onBest(n: T) {
        if (current == n) return
        current = n
        onChange(n)
    }

    /** Android 12+: [n] dejó de ser la mejor y no hay otra. */
    @Synchronized
    fun onBestLost(n: T) {
        if (current != n) return
        current = null
        onChange(null)
    }

    private fun recompute() {
        val best = pick()
        if (best == current) return
        current = best
        onChange(best)
    }

    /** La mejor de las conocidas; ante empate sin ventaja se queda la actual (no se salta de una a otra). */
    private fun pick(): T? {
        var best: T? = null
        var bestScore = Int.MIN_VALUE
        for ((n, c) in known) {
            val s = rank(c)
            if (s > bestScore || (s == bestScore && n == current)) {
                best = n
                bestScore = s
            }
        }
        return best
    }

    companion object {
        /** Validada antes que no validada; después Ethernet y Wi-Fi sobre móvil. */
        fun rank(c: Caps): Int = (if (c.validated) 100 else 0) + when (c.transport) {
            Transport.ETHERNET -> 30
            Transport.WIFI -> 20
            Transport.CELLULAR -> 10
            Transport.OTHER -> 0
        }
    }
}
