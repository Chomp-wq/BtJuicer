package com.secretsavior.vpn

/**
 * Detecta que el enlace aguas arriba está atascado: varias consultas seguidas caducan sin que
 * conteste NINGÚN servidor, en poco tiempo, y los envíos no fallaron (si fallan es que no hay red,
 * que es otra cosa). Sin Android.
 *
 * Es la señal que Android ya no ve: sin VPN, los timeouts de DNS de cada app cuentan para su
 * detección de «datos atascados»; con la VPN el DNS se atribuye a nuestra red y esa señal se pierde.
 */
class StallDetector(
    private val threshold: Int = STALL_QUERIES,
    private val windowMs: Long = STALL_WINDOW_MS,
) {
    private val times = ArrayDeque<Long>()
    private var armedAfter = Long.MIN_VALUE

    /**
     * Una consulta enviada en [sentAt] caducó en [now]. true = atasco: [threshold] seguidas dentro de
     * [windowMs]. Las que salieron antes del último atasco no cuentan: ya se atendieron en él.
     */
    @Synchronized
    fun expired(sentAt: Long, now: Long, sendsWorked: Boolean): Boolean {
        if (!sendsWorked || sentAt <= armedAfter) return false
        times.addLast(now)
        while (times.size > threshold) times.removeFirst()
        if (times.size >= threshold && now - times.first() <= windowMs) {
            times.clear()
            armedAfter = now
            return true
        }
        return false
    }

    /** Contestó alguien: el enlace vive y la racha se corta. */
    @Synchronized
    fun answered() = times.clear()

    /** Cambio de red o recuperación: se empieza de cero y lo enviado hasta ahora no cuenta. */
    @Synchronized
    fun reset(now: Long) {
        times.clear()
        armedAfter = now
    }

    companion object {
        const val STALL_QUERIES = 6
        const val STALL_WINDOW_MS = 10_000L
    }
}

/** Deja pasar como mucho una vez cada [gapMs]. Seguro entre hilos. */
class MinGap(private val gapMs: Long, private val clock: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private var last = Long.MIN_VALUE

    @Synchronized
    fun tryAcquire(): Boolean {
        val t = clock()
        if (last != Long.MIN_VALUE && t - last < gapMs) return false
        last = t
        return true
    }
}
