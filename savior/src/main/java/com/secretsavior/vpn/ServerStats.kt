package com.secretsavior.vpn

import java.net.Inet6Address
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * Qué servidores van mejor: RTT suavizado y pérdidas recientes de cada uno. Sin Android.
 *
 * Por qué: mandar cada consulta a los cuatro primarios (2 IPv4 + 2 IPv6) cuadruplica los paquetes
 * que un CGNAT de operador tiene que seguir, contra un resolutor gratuito. Con esto se manda a los
 * dos mejores (uno por familia si hay IPv6) y el resto sólo si la consulta tarda más de lo normal.
 *
 * Un servidor al que no se ha medido cuenta como [UNKNOWN_RTT_MS]: se prueba, pero no desplaza a
 * uno rápido ya medido. El que pierde seguido (dos fallos recientes sin contestar nada en medio)
 * pasa al final de la fila.
 */
class ServerStats(
    servers: List<InetSocketAddress>,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private class S {
        @Volatile var srtt = -1.0
        @Volatile var sampledAt = 0L
        @Volatile var misses = 0
        @Volatile var missAt = 0L
    }

    private val map = ConcurrentHashMap<InetSocketAddress, S>().also { m -> servers.forEach { m[it] = S() } }

    /** [addr] contestó en [ms]: media móvil (1/8, como el SRTT de TCP) y las pérdidas se olvidan. */
    fun answered(addr: InetSocketAddress, ms: Long) {
        val s = map[addr] ?: return
        val sample = ms.coerceIn(0, MAX_SAMPLE_MS).toDouble()
        val old = s.srtt
        s.srtt = if (old < 0 || clock() - s.sampledAt > SAMPLE_TTL_MS) sample else old + (sample - old) / 8
        s.sampledAt = clock()
        s.misses = 0
    }

    /** A [addr] se le preguntó y no contestó a tiempo. */
    fun missed(addr: InetSocketAddress) {
        val s = map[addr] ?: return
        val t = clock()
        s.misses = (if (t - s.missAt > LOSS_MEMORY_MS) 0 else s.misses) + 1
        s.missAt = t
    }

    /** Nueva red: lo medido en la anterior no vale ([rtt]); sólo se olvidan las pérdidas si es false. */
    fun reset(rtt: Boolean) {
        for (s in map.values) {
            s.misses = 0
            if (rtt) s.srtt = -1.0
        }
    }

    private fun losing(s: S) = s.misses >= LOSING_MISSES && clock() - s.missAt <= LOSS_MEMORY_MS

    fun isLosing(addr: InetSocketAddress): Boolean = map[addr]?.let { losing(it) } ?: false

    /** Coste para ordenar: el RTT (o el de por defecto), más lo que pesan las pérdidas recientes. */
    fun cost(addr: InetSocketAddress): Double {
        val s = map[addr] ?: return UNKNOWN_RTT_MS
        val t = clock()
        val base = if (s.srtt >= 0 && t - s.sampledAt <= SAMPLE_TTL_MS) s.srtt else UNKNOWN_RTT_MS
        val recent = if (t - s.missAt <= LOSS_MEMORY_MS) s.misses else 0
        return base + recent * MISS_COST_MS + (if (losing(s)) BACK_OF_THE_LINE else 0.0)
    }

    /** De mejor a peor; los empates conservan el orden de la lista (CleanBrowsing primero). */
    fun order(list: List<InetSocketAddress>): List<InetSocketAddress> = list.sortedBy { cost(it) }

    /**
     * A quién se manda primero: el mejor, y de segundo el mejor de la otra familia si hay IPv6 y no
     * está perdiendo; si no, el siguiente. Sin IPv6 (o sin ninguno IPv4 al que ir) se usa lo que haya.
     */
    fun initial(primaries: List<InetSocketAddress>, ipv6Works: Boolean, count: Int = 2): List<InetSocketAddress> {
        val usable = if (ipv6Works) primaries else primaries.filter { it.address !is Inet6Address }.ifEmpty { primaries }
        val ranked = order(usable)
        if (ranked.size <= count) return ranked
        val out = ArrayList<InetSocketAddress>(count)
        out += ranked[0]
        if (count > 1) {
            val firstV6 = ranked[0].address is Inet6Address
            val other = if (ipv6Works) ranked.firstOrNull { (it.address is Inet6Address) != firstV6 && !isLosing(it) } else null
            out += other ?: ranked[1]
            for (a in ranked) if (out.size < count && a !in out) out += a
        }
        return out
    }

    /** Cuánto esperar antes de preguntar también a los demás: 2,5 × el mejor RTT, entre 150 y 800 ms. */
    fun hedgeDelayMs(primaries: List<InetSocketAddress>): Long {
        val t = clock()
        val best = primaries.mapNotNull { map[it] }.filter { it.srtt >= 0 && t - it.sampledAt <= SAMPLE_TTL_MS }
            .minOfOrNull { it.srtt } ?: return DEFAULT_HEDGE_MS
        return (best * 2.5).toLong().coerceIn(HEDGE_MIN_MS, HEDGE_MAX_MS)
    }

    companion object {
        const val UNKNOWN_RTT_MS = 100.0
        const val MISS_COST_MS = 100.0
        const val BACK_OF_THE_LINE = 10_000.0
        const val LOSING_MISSES = 2
        const val LOSS_MEMORY_MS = 60_000L
        const val SAMPLE_TTL_MS = 5 * 60_000L
        const val MAX_SAMPLE_MS = 2_000L
        const val HEDGE_MIN_MS = 150L
        const val HEDGE_MAX_MS = 800L
        const val DEFAULT_HEDGE_MS = 300L
    }
}
