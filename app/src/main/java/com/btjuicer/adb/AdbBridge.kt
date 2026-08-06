package com.btjuicer.adb

import android.content.Context
import android.os.Build
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.security.PrivateKey
import java.security.cert.Certificate

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
private class ConnectionManager(
    private val identity: AdbKeys.Identity,
) : AbsAdbConnectionManager() {

    init {
        // Reached reflectively on purpose. Depending on whether the library
        // exposes a matching getter, Kotlin may see this as a property or as a
        // method, and picking wrong is a compile error in a file that could not
        // be compiled against the real library. Reflection works either way.
        runCatching {
            javaClass.superclass
                ?.getMethod("setApi", Int::class.javaPrimitiveType)
                ?.invoke(this, Build.VERSION.SDK_INT)
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
        const val TAG = "BTJuicerAdb"
        const val DISCOVERY_TIMEOUT_MS = 20_000L
        const val PAIRING_DISCOVERY_TIMEOUT_MS = 60_000L
    }

    private val discovery = AdbDiscovery(context)
    private val mutex = Mutex()

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
    suspend fun pair(pairingCode: String): Result<Unit> = mutex.withLock {
        val identity = AdbKeys.loadOrCreate(context)
            ?: return fail("No se pudo crear la identidad para ADB en este teléfono")

        _state.value = AdbState.Working("Buscando el puerto de emparejamiento…")
        val endpoint = discovery.find(AdbDiscovery.PAIRING_TYPE, PAIRING_DISCOVERY_TIMEOUT_MS)
            ?: return fail(
                "No apareció ningún puerto de emparejamiento. Deja abierta la ventana " +
                    "«Vincular dispositivo con código» mientras se busca.",
            )

        _state.value = AdbState.Working("Emparejando con $endpoint…")
        return withContext(Dispatchers.IO) {
            runCatching {
                val mgr = ConnectionManager(identity).also { manager = it }
                val ok = mgr.pair(endpoint.host, endpoint.port, pairingCode)
                check(ok) { "El código no fue aceptado" }
            }.fold(
                onSuccess = {
                    _state.value = AdbState.Paired
                    Result.success(Unit)
                },
                onFailure = {
                    Log.w(TAG, "pairing failed", it)
                    fail(it.message ?: "El emparejamiento falló")
                },
            )
        }
    }

    suspend fun connect(): Result<Unit> = mutex.withLock {
        val identity = AdbKeys.load(context)
            ?: return fail("Todavía no hay emparejamiento. Empareja primero.")

        _state.value = AdbState.Working("Buscando el puerto de depuración…")
        val endpoint = discovery.find(AdbDiscovery.CONNECT_TYPE, DISCOVERY_TIMEOUT_MS)
            ?: return fail(
                "No se encontró el puerto de depuración inalámbrica. Compruébalo: tiene que " +
                    "estar activada y el teléfono en la misma red Wi-Fi.",
            )

        _state.value = AdbState.Working("Conectando con $endpoint…")
        return withContext(Dispatchers.IO) {
            runCatching {
                val mgr = manager?.takeIf { it.isConnected } ?: ConnectionManager(identity)
                manager = mgr
                val ok = mgr.connect(endpoint.host, endpoint.port)
                check(ok) { "El demonio ADB rechazó la conexión" }
            }.fold(
                onSuccess = {
                    _state.value = AdbState.Connected(endpoint)
                    Result.success(Unit)
                },
                onFailure = {
                    Log.w(TAG, "connect failed", it)
                    fail(it.message ?: "La conexión falló")
                },
            )
        }
    }

    /** Runs a shell command and returns its combined output. */
    suspend fun shell(command: String): Result<String> = withContext(Dispatchers.IO) {
        val mgr = manager ?: return@withContext Result.failure(
            IllegalStateException("Sin conexión ADB"),
        )
        runCatching {
            val stream = mgr.openStream("shell:$command")
            try {
                stream.openInputStream().bufferedReader().readText()
            } finally {
                runCatching { stream.close() }
            }
        }.onFailure {
            Log.w(TAG, "shell failed: $command", it)
            // A dead connection is the usual cause; drop it so the next attempt
            // reconnects instead of failing forever against a stale socket.
            if (_state.value is AdbState.Connected) _state.value = AdbState.Paired
            runCatching { manager?.close() }
            manager = null
        }
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
