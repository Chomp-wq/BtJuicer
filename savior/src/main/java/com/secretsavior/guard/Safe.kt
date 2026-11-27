package com.secretsavior.guard

import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/**
 * Todo lo que el sistema o un manejador nuestro llama corre en el único proceso de la app, que
 * también lleva el túnel VPN: una excepción sin atrapar lo mata, Android derriba la VPN y resetea
 * todas las conexiones del teléfono. Por eso los puntos de entrada pasan por aquí.
 *
 * Se atrapa `Throwable` y no `Exception`: las ROM de fabricante lanzan NoSuchMethodError,
 * SecurityException, DeadObjectException... y un Error no lo coge `catch (e: Exception)`.
 */
object Safe {

    private const val TAG = "SecretSavior"
    private const val MAX_KINDS = 200

    /** Dónde se escribe; los tests lo cambian porque `Log` no existe en la JVM. */
    @Volatile
    var sink: (tag: String, msg: String, t: Throwable) -> Unit = { tag, msg, t -> Log.w(tag, msg, t) }

    private val seen = ConcurrentHashMap.newKeySet<String>()

    /**
     * Una vez por clase de fallo y sitio: un fallo que se repite en cada evento de accesibilidad
     * llenaría el registro (y gastaría CPU) sin decir nada nuevo.
     */
    fun shouldLog(where: String, t: Throwable): Boolean {
        if (seen.size >= MAX_KINDS) return false
        return seen.add(where + "|" + t.javaClass.name)
    }

    fun failed(where: String, t: Throwable) {
        try {
            if (shouldLog(where, t)) sink(TAG, "fallo en $where", t)
        } catch (_: Throwable) {
            // registrar nunca puede ser la causa de otro fallo
        }
    }

    internal fun resetForTest() = seen.clear()
}

/**
 * Ejecuta [block] sin dejar escapar nada. La cancelación de corrutinas sí se propaga: es el
 * mecanismo normal para pararlas, no un fallo.
 */
inline fun safely(where: String, block: () -> Unit) {
    try {
        block()
    } catch (t: Throwable) {
        if (t is java.util.concurrent.CancellationException) throw t
        Safe.failed(where, t)
    }
}

/** Como [safely], con el valor que se da si falla. */
inline fun <T> safelyOr(where: String, default: T, block: () -> T): T = try {
    block()
} catch (t: Throwable) {
    if (t is java.util.concurrent.CancellationException) throw t
    Safe.failed(where, t)
    default
}

/** Qué hacer con una excepción que nadie atrapó. Pura: se prueba sin Android. */
object UncaughtPolicy {
    enum class Action { DELEGATE, SWALLOW }

    /**
     * En el hilo principal el bucle de mensajes ya no existe: el proceso tiene que reiniciarse,
     * así que se pasa al manejador anterior. En un hilo auxiliar basta con que muera ese hilo,
     * salvo los del túnel (ver [isCritical]).
     */
    fun decide(onMainThread: Boolean, threadName: String = ""): Action =
        if (onMainThread || isCritical(threadName)) Action.DELEGATE else Action.SWALLOW

    /**
     * El lector del túnel y el receptor UDP: si mueren en silencio, `running` sigue en true sin
     * DNS y el teléfono entero se queda sin red. Peor que reiniciar: el proceso cae y el
     * watchdog / arranque vuelve a levantar el túnel.
     */
    fun isCritical(threadName: String): Boolean = CRITICAL.any { threadName.startsWith(it) }

    private val CRITICAL = listOf("savior-tun", "savior-dns")
}

/** Hilos con nombre: en el registro se ve cuál falló. */
class NamedThreads(private val prefix: String) : ThreadFactory {
    private val n = AtomicInteger()

    override fun newThread(r: Runnable): Thread =
        Thread(r, if (n.incrementAndGet() == 1) prefix else "$prefix-${n.get()}").apply { isDaemon = true }
}
