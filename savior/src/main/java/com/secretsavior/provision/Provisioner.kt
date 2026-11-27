package com.secretsavior.provision

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.secretsavior.R
import com.secretsavior.guard.Status
import com.secretsavior.guard.Watchdog
import com.secretsavior.provision.ShellVerdict.Goal
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface ProvisionState {
    data object Idle : ProvisionState
    data class WaitingCode(val goal: Goal) : ProvisionState
    data class Working(val goal: Goal, val step: String) : ProvisionState
    data class Done(val goal: Goal, val ok: Boolean, val message: String) : ProvisionState
}

/**
 * Vincular por depuración inalámbrica y ejecutar el comando, sin ordenador.
 *
 * El diálogo «Vincular con código» de Ajustes se cierra en cuanto Ajustes pasa a segundo plano,
 * así que el código no se puede teclear en la app: se escribe en una notificación con campo de
 * respuesta (el mismo truco que Shizuku), sin salir de Ajustes. BT Juicer lo resuelve con
 * pantalla partida, que aquí no sirve: hace falta poder seguir en Ajustes.
 */
object Provisioner {

    private const val TAG = "SecretSaviorProv"
    private const val CHANNEL = "savior_provision"
    private const val NOTIF_ID = 4107
    const val KEY_CODE = "code"
    const val ACTION_REPLY = "com.secretsavior.PROVISION_CODE"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow<ProvisionState>(ProvisionState.Idle)
    val state: StateFlow<ProvisionState> = _state.asStateFlow()

    @Volatile
    private var adb: AdbLink? = null

    @Synchronized
    private fun link(c: Context): AdbLink =
        adb ?: AdbLink(c.applicationContext).also { adb = it }

    /** Ya hubo un emparejamiento en este teléfono: basta conectar, sin código. */
    fun alreadyPaired(c: Context): Boolean = runCatching { AdbKeys.load(c) != null }.getOrDefault(false)

    /** Pone la notificación con el campo del código y espera a que se escriba. */
    fun begin(c: Context, goal: Goal) {
        if (_state.value is ProvisionState.Working) return
        _state.value = ProvisionState.WaitingCode(goal)
        notifyWaiting(c.applicationContext, goal, null)
    }

    /** Ya vinculado antes: conecta y ejecuta, sin código. */
    fun runPaired(c: Context, goal: Goal) {
        if (_state.value is ProvisionState.Working) return
        val ctx = c.applicationContext
        _state.value = ProvisionState.Working(goal, "Conectando…")
        scope.launch { connectAndRun(ctx, goal, link(ctx)) }
    }

    /** Cierra el diálogo y retira la notificación (salvo que esté trabajando). */
    fun reset(c: Context) {
        if (_state.value is ProvisionState.Working) return
        _state.value = ProvisionState.Idle
        runCatching { nm(c.applicationContext).cancel(NOTIF_ID) }
    }

    /**
     * Llega el código escrito en la notificación. [onPaired] se llama cuando el emparejamiento
     * acaba (bien o mal): el receptor suelta ahí su `goAsync`, porque un receptor no puede
     * quedarse vivo lo que tarda el resto.
     */
    fun onCode(c: Context, raw: CharSequence?, onPaired: () -> Unit) {
        val ctx = c.applicationContext
        val goal = (state.value as? ProvisionState.WaitingCode)?.goal
        if (goal == null) {
            onPaired()
            return
        }
        val code = ShellVerdict.parseCode(raw)
        if (code == null) {
            notifyWaiting(ctx, goal, "El código tiene 6 cifras. Inténtalo otra vez.")
            onPaired()
            return
        }
        _state.value = ProvisionState.Working(goal, "Vinculando…")
        notifyProgress(ctx, "Vinculando…")
        val adb = link(ctx)
        scope.launch {
            // Si el emparejamiento se atasca, el receptor se suelta igualmente a los 8 s.
            val guard = launch { delay(8_000); onPaired() }
            val paired = adb.pair(code)
            guard.cancel()
            onPaired()
            if (paired.isFailure) {
                finish(ctx, goal, ShellVerdict.Verdict(false, explainPairFailure(paired.exceptionOrNull()?.message)))
                return@launch
            }
            connectAndRun(ctx, goal, adb)
        }
    }

    private suspend fun connectAndRun(ctx: Context, goal: Goal, adb: AdbLink) {
        step(ctx, goal, "Conectando con el teléfono…")
        val connected = adb.connect()
        if (connected.isFailure) {
            finish(ctx, goal, ShellVerdict.Verdict(false, connected.exceptionOrNull()?.message ?: "No se pudo conectar."))
            return
        }
        step(ctx, goal, "Aplicando el cambio…")
        val out = adb.shell(ShellVerdict.command(goal))
        val verified = when (goal) {
            Goal.SECURE_SETTINGS -> Status.hasSecureSettings(ctx)
            Goal.DEVICE_OWNER -> runCatching { Status.isDeviceOwner(ctx) }.getOrDefault(false)
        }
        val verdict = if (out.isFailure && !verified) {
            ShellVerdict.Verdict(false, out.exceptionOrNull()?.message ?: "Sin respuesta.")
        } else {
            ShellVerdict.interpret(goal, out.getOrNull().orEmpty(), verified)
        }
        // La sesión ADB ya no hace falta; la vinculación queda guardada para otra vez.
        adb.disconnect()
        if (verdict.ok) runCatching { Watchdog.ensure(ctx) }
        finish(ctx, goal, verdict)
    }

    private fun explainPairFailure(raw: String?): String =
        (raw ?: "El emparejamiento falló") + "\n\nComprueba que la ventana «Vincular dispositivo con código» " +
            "seguía abierta y que el código era el de esa ventana. Vuelve a pulsar «Preparar el código»."

    private fun step(ctx: Context, goal: Goal, text: String) {
        _state.value = ProvisionState.Working(goal, text)
        notifyProgress(ctx, text)
    }

    private fun finish(ctx: Context, goal: Goal, v: ShellVerdict.Verdict) {
        _state.value = ProvisionState.Done(goal, v.ok, v.message)
        notifyResult(ctx, if (v.ok) "Listo" else "No se pudo", v.message)
    }

    // --- Notificación ------------------------------------------------------------------

    private fun nm(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun builder(c: Context): Notification.Builder {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm(c).createNotificationChannel(
                NotificationChannel(CHANNEL, "Vincular sin ordenador", NotificationManager.IMPORTANCE_HIGH),
            )
            Notification.Builder(c, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(c)
        }
        return b.setSmallIcon(R.drawable.ic_notification)
    }

    private fun notifyWaiting(c: Context, goal: Goal, hint: String?) {
        try {
            val input = RemoteInput.Builder(KEY_CODE).setLabel("Código de vinculación").build()
            val intent = Intent(ACTION_REPLY).setClass(c, ProvisionReceiver::class.java)
            // Mutable: el sistema rellena el texto escrito. El intent es explícito.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(c, 0, intent, flags)
            val action = Notification.Action.Builder(null, "Escribir el código", pi).addRemoteInput(input).build()
            val what = if (goal == Goal.DEVICE_OWNER) "propietaria del dispositivo" else "autocuración"
            val body = hint ?: "Con la ventana «Vincular con código» abierta en Ajustes, toca «Escribir el código» " +
                "aquí y teclea las 6 cifras. No hace falta volver a la app."
            nm(c).notify(
                NOTIF_ID,
                builder(c)
                    .setContentTitle("Código de vinculación ($what)")
                    .setContentText(body)
                    .setStyle(Notification.BigTextStyle().bigText(body))
                    .setOngoing(true)
                    .addAction(action)
                    .build(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo mostrar la notificación", e)
        }
    }

    private fun notifyProgress(c: Context, text: String) {
        try {
            nm(c).notify(
                NOTIF_ID,
                builder(c).setContentTitle("Secret Savior").setContentText(text).setOngoing(true).setOnlyAlertOnce(true).build(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "notificación", e)
        }
    }

    private fun notifyResult(c: Context, title: String, text: String) {
        try {
            nm(c).notify(
                NOTIF_ID,
                builder(c).setContentTitle(title).setContentText(text.lineSequence().first())
                    .setStyle(Notification.BigTextStyle().bigText(text)).setAutoCancel(true).build(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "notificación", e)
        }
    }
}

/** Recibe lo escrito en la notificación del código (ver el bloque del manifiesto). */
class ProvisionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Provisioner.ACTION_REPLY) return
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Provisioner.KEY_CODE)
        val pending = goAsync()
        Provisioner.onCode(context, text) { runCatching { pending.finish() } }
    }
}
