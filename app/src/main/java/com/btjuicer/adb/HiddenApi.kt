package com.btjuicer.adb

import android.util.Log
import org.lsposed.hiddenapibypass.HiddenApiBypass
import javax.net.ssl.SSLSocket

/**
 * Lifts Android's hidden-API reflection filter far enough to finish an ADB
 * pairing.
 *
 * ### What breaks without this
 *
 * The pairing handshake has to bind the SPAKE2 exchange to the TLS session, and
 * the only way to get that binding is to ask the TLS stack to export keying
 * material (RFC 5705). Android has no public API for it. The one that exists is
 * `com.android.org.conscrypt.Conscrypt.exportKeyingMaterial`, which is a
 * platform-internal class, so since Android 9 the runtime hides its members from
 * reflection. The shape of that filter is what makes the failure so misleading:
 * classes are never hidden, only their members, so the class resolves and only
 * the lookup fails. What you see is
 *
 *     java.lang.NoSuchMethodException:
 *       com.android.org.conscrypt.Conscrypt.exportKeyingMaterial
 *       [class javax.net.ssl.SSLSocket, class java.lang.String, class [B, int]
 *
 * which reads as "this method does not exist". It does; it is checked into
 * Android 15 with exactly that signature. It is simply not ours to look up.
 *
 * ### What this does, and what it does not
 *
 * The runtime keeps a per-process exemption list. Adding to it makes hidden
 * members visible to reflection **inside this app only**. It grants no
 * permission, reaches nothing outside the process, and changes nothing for any
 * other app. It is the reason Shizuku, Island, and most root-adjacent tools
 * work at all.
 *
 * The exemption is kept as narrow as it can be while still working: Conscrypt
 * first, and only if that turns out not to be enough does it fall back to
 * exempting everything. Whether the narrow one sufficed is checked by looking
 * the method up rather than assumed, and logged either way.
 */
internal object HiddenApi {

    private const val TAG = "BTJuicerAdb"

    /** Just the TLS stack — the only hidden API the ADB client is known to need. */
    private val CONSCRYPT = arrayOf("Lcom/android/org/conscrypt/", "Lorg/conscrypt/")

    /** Every class signature begins with `L`, so this is "all of it". */
    private const val EVERYTHING = "L"

    @Volatile
    private var done = false

    /** Idempotent; safe to call before every pairing attempt. */
    @Synchronized
    fun allow() {
        if (done) return
        done = true

        if (exportVisible()) {
            Log.i(TAG, "hidden API: keying-material export already visible")
            return
        }

        runCatching { HiddenApiBypass.addHiddenApiExemptions(*CONSCRYPT) }
            .onFailure { Log.w(TAG, "hidden API: narrow exemption failed", it) }
        if (exportVisible()) {
            Log.i(TAG, "hidden API: Conscrypt exempted")
            return
        }

        runCatching { HiddenApiBypass.addHiddenApiExemptions(EVERYTHING) }
            .onFailure { Log.w(TAG, "hidden API: broad exemption failed", it) }
        if (exportVisible()) {
            Log.i(TAG, "hidden API: exempted everything")
        } else {
            // Not fatal here: the pairing will fail on its own and say so. This
            // line is what turns that failure into something diagnosable.
            Log.w(TAG, "hidden API: keying-material export still hidden; pairing will fail")
        }
    }

    private fun exportVisible(): Boolean = runCatching {
        Class.forName("com.android.org.conscrypt.Conscrypt").getMethod(
            "exportKeyingMaterial",
            SSLSocket::class.java,
            String::class.java,
            ByteArray::class.java,
            Int::class.javaPrimitiveType,
        )
        true
    }.getOrDefault(false)
}
