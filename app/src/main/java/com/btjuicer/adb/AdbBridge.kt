package com.btjuicer.adb

import android.content.Context
import android.os.Build
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import java.io.ByteArrayOutputStream
import java.security.PrivateKey
import java.security.cert.Certificate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The only file that touches the ADB library.
 *
 * Everything else in the app works without it, and every call here is wrapped so
 * a failure surfaces as a message rather than a crash. Kept deliberately small
 * and in one place: it is the one piece that could not be compiled against the
 * real library while it was written, so if its API differs, this is the single
 * file to correct.
 *
 * ### Why an ADB connection at all
 *
 * Reading the negotiated Bluetooth codec needs `dumpsys`, and `dumpsys` needs
 * the DUMP permission, which only the shell user holds. Connecting to the
 * phone's own ADB daemon is how an ordinary app borrows that — the same
 * mechanism Shizuku uses, minus the second app.
 *
 * It cannot *set* the codec: no shell command exists for that, and the write
 * path would need a binder call from a shell-UID process.
 */
private const val TAG = "BTJuicerAdb"

private class ConnectionManager(
    private val identity: AdbKeys.Identity,
) : AbsAdbConnectionManager() {

    init {
        // Reached reflectively on purpose. Depending on whether the library
        // exposes a matching getter, Kotlin may see this as a property or as a
        // method, and picking wrong is a compile error in a file that could not
        // be compiled against the real library. Reflection works either way.
        //
        // It matters more than it looks: the API level is what tells the library
        // to speak TLS instead of the old challenge-response auth. Getting it
        // wrong fails at connect time, far from here, so the failure is logged
        // rather than swallowed — and both lookups are tried, since a protected
        // setter is invisible to getMethod.
        val superclass = javaClass.superclass
        val setApi = superclass?.let { type ->
            runCatching { type.getMethod("setApi", Int::class.javaPrimitiveType) }.getOrNull()
                ?: runCatching {
                    type.getDeclaredMethod("setApi", Int::class.javaPrimitiveType)
                        .apply { isAccessible = true }
                }.getOrNull()
        }
        if (setApi == null) {
            Log.w(TAG, "setApi not found on ${superclass?.name}; the library will use its default")
        } else {
            runCatching { setApi.invoke(this, Build.VERSION.SDK_INT) }
                .onFailure { Log.w(TAG, "setApi failed", it) }
        }
    }

    override fun getPrivateKey(): PrivateKey = identity.privateKey

    override fun getCertificate(): Certificate = identity.certificate

    override fun getDeviceName(): String = "BT Juicer"
}

sealed interface AdbState {
    /** No identity yet, or the user has never paired. */
    data object NotPaired : AdbState

    data class Working(val step: String) : AdbState

    data object Paired : AdbState

    data class Connected(val endpoint: Endpoint) : AdbState

    data class Error(val message: String) : AdbState
}

class AdbLink(private val context: Context) {

    private companion object {
        const val DISCOVERY_TIMEOUT_MS = 20_000L

        /**
         * Ceiling for a single command. Generous on purpose: the privileged
         * helper starts a process and waits for the Bluetooth link to
         * renegotiate, which is several seconds of legitimate silence. Anything
         * past this is not slow, it is gone.
         */
        const val COMMAND_TIMEOUT_MS = 30_000L
        const val PAIRING_DISCOVERY_TIMEOUT_MS = 60_000L
    }

    private val discovery = AdbDiscovery(context)
    private val mutex = Mutex()

    /** Outlives any single command, because its whole job is to interrupt one. */
    private val watchdogScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Separate from [mutex] because pairing holds that one for up to a minute
     * while it waits for the user to open a dialog. Its job is to keep the
     * background codec poll from opening a second stream on top of a privileged
     * command that is halfway through — one command at a time on one socket.
     */
    private val shellMutex = Mutex()

    private val _state = MutableStateFlow<AdbState>(AdbState.NotPaired)
    val state: StateFlow<AdbState> = _state.asStateFlow()

    @Volatile
    private var manager: ConnectionManager? = null

    fun markPaired(paired: Boolean) {
        if (_state.value is AdbState.Connected) return
        _state.value = if (paired) AdbState.Paired else AdbState.NotPaired
    }

    /**
     * The pairing service only exists while the "Pair device with pairing code"
     * dialog is open on screen, hence the long discovery window: the user has to
     * go and open it.
     */
    suspend fun pair(pairingCode: String, manual: Endpoint? = null): Result<Unit> =
        mutex.withLock {
            HiddenApi.allow()

            val identity = AdbKeys.loadOrCreate(context)
                ?: return fail("No se pudo crear la identidad para ADB en este teléfono")

            val candidates = manual?.let(::listOf) ?: run {
                _state.value = AdbState.Working("Buscando el puerto de emparejamiento…")
                discovery.findAll(AdbDiscovery.PAIRING_TYPE, PAIRING_DISCOVERY_TIMEOUT_MS)
            }
            if (candidates.isEmpty()) {
                return fail(
                    "No apareció ningún puerto de emparejamiento. Deja abierta la ventana " +
                        "«Vincular dispositivo con código» mientras se busca.",
                )
            }

            return attempt(candidates, "Emparejando con") { endpoint ->
                val mgr = ConnectionManager(identity).also { manager = it }
                mgr.pair(endpoint.host, endpoint.port, pairingCode)
            }.fold(
                onSuccess = {
                    _state.value = AdbState.Paired
                    Result.success(Unit)
                },
                onFailure = { fail(it.message ?: "El emparejamiento falló") },
            )
        }

    suspend fun connect(manual: Endpoint? = null): Result<Unit> = mutex.withLock {
        HiddenApi.allow()

        val identity = AdbKeys.load(context)
            ?: return fail("Todavía no hay emparejamiento. Empareja primero.")

        val candidates = manual?.let(::listOf) ?: run {
            _state.value = AdbState.Working("Buscando el puerto de depuración…")
            discovery.findAll(AdbDiscovery.CONNECT_TYPE, DISCOVERY_TIMEOUT_MS)
        }
        if (candidates.isEmpty()) {
            return fail(
                "No se encontró el puerto de depuración inalámbrica. Compruébalo: tiene que " +
                    "estar activada y el teléfono en la misma red Wi-Fi.",
            )
        }

        return attempt(candidates, "Conectando con") { endpoint ->
            // Always a fresh manager. Reusing one because it claims to be
            // connected is how a socket from a previous session got kept alive
            // on paper while answering nothing.
            runCatching { manager?.close() }
            val mgr = ConnectionManager(identity).also { manager = it }
            mgr.connect(endpoint.host, endpoint.port)
        }.fold(
            onSuccess = { endpoint ->
                _state.value = AdbState.Connected(endpoint)
                Result.success(Unit)
            },
            onFailure = { fail(it.message ?: "La conexión falló") },
        )
    }

    /**
     * Tries every candidate and keeps the one that answers.
     *
     * mDNS hands back stale entries alongside live ones and gives no way to tell
     * them apart, so the only honest test of an endpoint is to dial it. A dead
     * one refuses immediately; the cost of trying it is nothing next to what the
     * alternative cost — an app that confidently dialled last week's port and
     * never got anywhere.
     */
    private suspend fun attempt(
        candidates: List<Endpoint>,
        step: String,
        action: (Endpoint) -> Boolean,
    ): Result<Endpoint> = withContext(Dispatchers.IO) {
        val failures = mutableListOf<String>()
        for (endpoint in candidates) {
            _state.value = AdbState.Working("$step $endpoint…")
            val outcome = runCatching { action(endpoint) }
            if (outcome.getOrDefault(false)) return@withContext Result.success(endpoint)

            val why = outcome.exceptionOrNull()?.message ?: "rechazado"
            Log.w(TAG, "$step $endpoint failed: $why")
            failures += "$endpoint ($why)"
        }
        Result.failure(
            IllegalStateException(
                if (failures.size == 1) {
                    "No respondió ${failures.first()}"
                } else {
                    "Ninguna de las direcciones respondió: ${failures.joinToString(", ")}"
                },
            ),
        )
    }

    /**
     * Runs a shell command and returns its combined output.
     *
     * Two things here are the result of watching this go wrong on a real phone.
     *
     * The output is accumulated as it arrives instead of being read in one go,
     * and **a stream that dies after it has already answered counts as a
     * success**. The daemon tears the channel down the instant the command
     * exits; whether the last read comes back as an end-of-file or as
     * `Stream closed.` is a race in the library, not a real failure, and a
     * command that printed everything it had to say should not be thrown away
     * because of how its ending was delivered.
     *
     * And a failed command no longer costs the connection. The old code closed
     * the manager on any error on the theory that a dead socket was the usual
     * cause — but the usual cause turned out to be the command, and dropping
     * the connection sent the user back to reconnecting for no reason.
     *
     * The watchdog is the third thing, and it is not optional. Commands are
     * serialised on one socket, so a read that never returns does not stall one
     * command — it stalls every command after it, for good, while the app goes
     * on claiming to be connected. Cancelling the coroutine would not help: a
     * blocking socket read ignores cancellation. Closing the stream from
     * somewhere else is the only thing that unblocks it.
     */
    suspend fun shell(command: String): Result<String> = shellMutex.withLock {
        val mgr = manager ?: return Result.failure(IllegalStateException("Sin conexión ADB"))

        withContext(Dispatchers.IO) {
            val collected = ByteArrayOutputStream()
            var timedOut = false
            val outcome = runCatching {
                val stream = mgr.openStream("shell:$command")
                val watchdog = watchdogScope.launch {
                    delay(COMMAND_TIMEOUT_MS)
                    timedOut = true
                    runCatching { stream.close() }
                }
                try {
                    val input = stream.openInputStream()
                    val buffer = ByteArray(8_192)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        collected.write(buffer, 0, read)
                    }
                } finally {
                    watchdog.cancel()
                    runCatching { stream.close() }
                }
            }
            // Decoded once at the end: a chunk boundary can land in the middle
            // of a multi-byte character, and device names are not all ASCII.
            val output = collected.toString(Charsets.UTF_8.name())

            if (!timedOut && (outcome.isSuccess || output.isNotEmpty())) {
                return@withContext Result.success(output)
            }

            val failure = when {
                timedOut -> IllegalStateException(
                    "El comando no respondió en ${COMMAND_TIMEOUT_MS / 1000} s. " +
                        "Se ha soltado la conexión; vuelve a conectar.",
                )
                else -> outcome.exceptionOrNull() ?: IllegalStateException("Sin respuesta")
            }
            Log.w(TAG, "shell failed: $command", failure)

            // A command that never answered means the channel is gone, whatever
            // the library still believes. `isConnected` reports the handshake,
            // not the socket, so it happily says yes to a connection that died
            // with the Wi-Fi — which leaves the app claiming to be connected
            // while nothing works and offering no way out.
            if (timedOut || !isLive()) {
                _state.value = AdbState.Paired
                runCatching { manager?.close() }
                manager = null
            }
            Result.failure(failure)
        }
    }

    /** Whether the daemon is still on the other end, as far as the library knows. */
    private fun isLive(): Boolean =
        runCatching { manager?.isConnected == true }.getOrDefault(false)

    /** Drops whatever is there and dials again, for when the socket has gone stale. */
    suspend fun reconnect(manual: Endpoint? = null): Result<Unit> {
        disconnect()
        return connect(manual)
    }

    fun disconnect() {
        runCatching { manager?.close() }
        manager = null
        if (_state.value is AdbState.Connected) _state.value = AdbState.Paired
    }

    /** Forgets the identity; the daemon will demand pairing again. */
    fun forget() {
        disconnect()
        AdbKeys.clear(context)
        _state.value = AdbState.NotPaired
    }

    private fun fail(message: String): Result<Unit> {
        _state.value = AdbState.Error(message)
        return Result.failure(IllegalStateException(message))
    }
}
