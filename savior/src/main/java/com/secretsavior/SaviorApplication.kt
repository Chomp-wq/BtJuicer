package com.secretsavior

import android.app.Application
import android.os.Looper
import android.util.Log
import com.secretsavior.guard.UncaughtPolicy

/**
 * Un solo proceso para la interfaz, el guardián y el túnel VPN: si cae por una excepción en un
 * hilo secundario, Android derriba la VPN y resetea todas las conexiones del teléfono. Un hilo
 * auxiliar muerto es mucho más barato que eso, así que esos fallos se registran y el proceso sigue.
 */
class SaviorApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        try {
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                val main = try {
                    thread === Looper.getMainLooper().thread
                } catch (_: Throwable) {
                    true // sin saberlo, se trata como el principal: lo conservador es reiniciar
                }
                when (UncaughtPolicy.decide(main, thread.name.orEmpty())) {
                    UncaughtPolicy.Action.SWALLOW ->
                        try {
                            Log.e("SecretSavior", "hilo «${thread.name}» muerto, el proceso sigue", error)
                        } catch (_: Throwable) {
                        }
                    UncaughtPolicy.Action.DELEGATE -> previous?.uncaughtException(thread, error)
                }
            }
        } catch (_: Throwable) {
        }
    }
}
