package com.btjuicer.adb

import android.content.Context
import android.util.Log

/**
 * Everything the privileged helper reported, as plain key/value pairs.
 *
 * Deliberately untyped: the helper is the part most likely to grow a new field,
 * and a map means adding one needs no change on this side.
 */
data class PrivReport(val fields: Map<String, String>, val raw: String) {

    val error: String? get() = fields["error"]

    /** False means the shell user could not read the codec on this ROM. */
    val privileged: Boolean get() = fields["privileged"] == "true"

    val deviceName: String get() = fields["device_name"].orEmpty()

    val selectable: List<Int>
        get() = fields["selectable"].orEmpty()
            .split(',')
            .mapNotNull { it.trim().toIntOrNull() }

    companion object {
        /**
         * Harvests the `BTJ:` lines out of whatever the shell sent back.
         *
         * Everything else is ignored on purpose: `app_process` and the runtime
         * print their own warnings, and a vendor shell adds its own noise. The
         * value may itself contain `=` — exception messages do — so only the
         * first one separates.
         */
        fun of(output: String): PrivReport {
            val fields = LinkedHashMap<String, String>()
            for (line in output.lineSequence()) {
                val body = line.trim().removePrefix("BTJ:").takeIf { it != line.trim() } ?: continue
                val split = body.indexOf('=')
                if (split <= 0) continue
                fields[body.substring(0, split)] = body.substring(split + 1)
            }
            return PrivReport(fields, output)
        }
    }

    fun status(prefix: String): CodecStatus? {
        val codec = fields["${prefix}_codec"]?.toIntOrNull() ?: return null
        return CodecStatus(
            codecType = codec,
            // getSampleRate() and getBitsPerSample() return the same bit masks
            // the dumpsys text prints, so both paths land on one model.
            sampleRateFlags = fields["${prefix}_rate"]?.toIntOrNull() ?: 0,
            bitsPerSampleFlags = fields["${prefix}_bits"]?.toIntOrNull() ?: 0,
            codecSpecific1 = fields["${prefix}_specific1"]?.toLongOrNull() ?: 0L,
            selectableCodecs = selectable,
        )
    }
}

/**
 * Runs BT Juicer's privileged half as the shell user, over the ADB link.
 *
 * The command is the whole trick:
 *
 *     CLASSPATH=<our apk> app_process /system/bin com.btjuicer.priv.Main set …
 *
 * `app_process` is the same binary the system uses to start every app, and
 * pointing it at our own APK runs our class in a process owned by uid 2000 —
 * which holds BLUETOOTH_PRIVILEGED, the permission that gates writing the codec.
 * No second app, no root: the ADB connection the user already granted is what
 * makes it possible.
 */
class CodecControl(private val adb: AdbLink, private val context: Context) {

    private companion object {
        const val TAG = "BTJuicerAdb"
        const val ENTRY = "com.btjuicer.priv.Main"
    }

    suspend fun probe(address: String?): Result<PrivReport> = run("probe", address)

    /**
     * @param quality only meaningful for LDAC, where the playback tier travels
     *   in `codecSpecific1`. Null leaves it to the stack.
     */
    suspend fun apply(
        address: String?,
        codecType: Int,
        quality: LdacQuality?,
    ): Result<PrivReport> = run(
        "set",
        address,
        codecType.toString(),
        (quality?.raw ?: -1L).toString(),
    )

    private suspend fun run(vararg args: String?): Result<PrivReport> {
        if (adb.state.value !is AdbState.Connected) {
            return Result.failure(IllegalStateException("Sin conexión ADB"))
        }

        val command = buildString {
            // The shell starts in a directory the shell user cannot write to,
            // and app_process wants somewhere to put its dex cache.
            append("cd /data/local/tmp 2>/dev/null; ")
            // Bookends. Without them a helper that dies before its first line is
            // indistinguishable from a command that never ran, and the two need
            // completely different fixes. The exit code says which.
            append("echo BTJ:shell=ok; ")
            append("CLASSPATH=").append(quote(context.applicationInfo.sourceDir))
            append(" app_process /system/bin --nice-name=btjuicer_priv ").append(ENTRY)
            for (arg in args) {
                append(' ').append(quote(arg?.takeIf { it.isNotEmpty() } ?: "-"))
            }
            append("; echo BTJ:exit=\$?")
        }

        val output = adb.shell(command).getOrElse { return Result.failure(it) }
        val report = PrivReport.of(output)
        Log.i(TAG, "priv ${args.firstOrNull()} -> ${report.fields}")

        // "uid" is the helper's first line, so its absence means app_process
        // never reached our class — a broken APK path, a ROM that blocks it, or
        // a crash before anything was printed. The raw output carries whatever
        // the runtime said on its way out, which is the only clue there is.
        if (!report.fields.containsKey("uid")) {
            val reached = report.fields.containsKey("shell")
            return Result.failure(
                IllegalStateException(
                    buildString {
                        append(
                            if (reached) {
                                "El ayudante no llegó a arrancar"
                            } else {
                                "El comando no llegó a ejecutarse"
                            },
                        )
                        report.fields["exit"]?.let { append(" (código $it)") }
                        append(". Respuesta: ")
                        append(output.trim().takeLast(400).ifEmpty { "(vacía)" })
                    },
                ),
            )
        }
        return Result.success(report)
    }

    /**
     * Single quotes, because APK paths are not tame: they carry `~~` and `==`
     * from the installer's directory names, and an unquoted one is a shell
     * expansion waiting to happen.
     */
    private fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"
}
