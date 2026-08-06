package com.btjuicer.adb

/**
 * Constants of the hidden `android.bluetooth.BluetoothCodecConfig`, duplicated
 * here because that class is @SystemApi and absent from the public SDK. We never
 * touch the class — these are only used to decode the numbers that
 * `dumpsys bluetooth_manager` prints.
 */
object CodecType {
    const val SBC = 0
    const val AAC = 1
    const val APTX = 2
    const val APTX_HD = 3
    const val LDAC = 4
    const val LC3 = 5
    const val OPUS = 6
    const val INVALID = 1_000_000

    fun label(type: Int): String = when (type) {
        SBC -> "SBC"
        AAC -> "AAC"
        APTX -> "aptX"
        APTX_HD -> "aptX HD"
        LDAC -> "LDAC"
        LC3 -> "LC3"
        OPUS -> "Opus"
        else -> "—"
    }
}

private val SAMPLE_RATES = listOf(
    0x1 to 44_100,
    0x2 to 48_000,
    0x4 to 88_200,
    0x8 to 96_000,
    0x10 to 176_400,
    0x20 to 192_000,
)

private val BIT_DEPTHS = listOf(0x1 to 16, 0x2 to 24, 0x4 to 32)

/** LDAC's playback-quality tier travels in `codecSpecific1`. */
enum class LdacQuality(val raw: Long, val label: String, val bitrate: String) {
    HIGH(1000L, "Calidad de audio", "990 / 909 kbps"),
    MID(1001L, "Equilibrado", "660 / 606 kbps"),
    LOW(1002L, "Calidad de conexión", "330 / 303 kbps"),
    ADAPTIVE(1003L, "Mejor esfuerzo", "adaptativo"),
    ;

    companion object {
        fun fromRaw(raw: Long): LdacQuality? = entries.firstOrNull { it.raw == raw }
    }
}

enum class CodecGrade { EXCELLENT, GOOD, DEGRADED, BASIC, UNKNOWN }

data class CodecStatus(
    val codecType: Int = CodecType.INVALID,
    val sampleRateFlags: Int = 0,
    val bitsPerSampleFlags: Int = 0,
    val codecSpecific1: Long = 0L,
    /** Codec types the sink advertised, when the dump lists them. */
    val selectableCodecs: List<Int> = emptyList(),
    val readAt: Long = System.currentTimeMillis(),
) {
    val sampleRateHz: Int
        get() = SAMPLE_RATES.firstOrNull { (bit, _) -> sampleRateFlags and bit != 0 }?.second ?: 0

    val bits: Int
        get() = BIT_DEPTHS.firstOrNull { (bit, _) -> bitsPerSampleFlags and bit != 0 }?.second ?: 0

    val ldacQuality: LdacQuality?
        get() = if (codecType == CodecType.LDAC) LdacQuality.fromRaw(codecSpecific1) else null

    val supportsLdac: Boolean get() = selectableCodecs.contains(CodecType.LDAC)

    val grade: CodecGrade
        get() = when {
            codecType == CodecType.INVALID -> CodecGrade.UNKNOWN
            codecType == CodecType.LDAC -> when (ldacQuality) {
                LdacQuality.HIGH -> CodecGrade.EXCELLENT
                LdacQuality.ADAPTIVE, null -> CodecGrade.GOOD
                LdacQuality.MID, LdacQuality.LOW -> CodecGrade.DEGRADED
            }

            codecType == CodecType.LC3 -> CodecGrade.GOOD
            else -> CodecGrade.BASIC
        }

    fun headline(): String {
        if (codecType == CodecType.INVALID) return "Sin códec negociado"
        val rate = if (sampleRateHz > 0) "%.1f kHz".format(sampleRateHz / 1000.0) else "—"
        val depth = if (bits > 0) "$bits bit" else "—"
        return "${CodecType.label(codecType)} · $rate / $depth"
    }

    /** The second line: for LDAC this is the number that actually matters. */
    fun subline(): String = ldacQuality?.let { "${it.label} · ${it.bitrate}" } ?: ""
}

/**
 * Reads `BluetoothCodecConfig.toString()` out of `dumpsys bluetooth_manager`:
 *
 *   mCodecConfig: {codecName:LDAC,mCodecType:4,mCodecPriority:1000000,
 *   mSampleRate:0x2(48000),mBitsPerSample:0x2(24),mChannelMode:0x2(STEREO),
 *   mCodecSpecific1:1003,...}
 *
 * Everything is matched by key name rather than position, and every field
 * degrades to a default, because vendor ROMs reorder and extend this dump.
 */
object DumpsysCodec {

    private val CONFIG_BLOCK = Regex("""mCodecConfig:\s*\{([^}]*)}""")
    private val SELECTABLE_BLOCK =
        Regex("""mCodecsSelectableCapabilities:\s*\[(.*?)]""", RegexOption.DOT_MATCHES_ALL)
    private val CODEC_TYPE_IN_ENTRY = Regex("""mCodecType:\s*(-?\d+)""")

    fun parse(dump: String): CodecStatus? {
        val block = CONFIG_BLOCK.find(dump)?.groupValues?.get(1) ?: return null
        val codecType = intField(block, "mCodecType") ?: return null

        val selectable = SELECTABLE_BLOCK.find(dump)?.groupValues?.get(1)?.let { list ->
            CODEC_TYPE_IN_ENTRY.findAll(list)
                .mapNotNull { it.groupValues[1].toIntOrNull() }
                .filter { it != CodecType.INVALID }
                .distinct()
                .toList()
        } ?: emptyList()

        return CodecStatus(
            codecType = codecType,
            sampleRateFlags = maskField(block, "mSampleRate") ?: 0,
            bitsPerSampleFlags = maskField(block, "mBitsPerSample") ?: 0,
            codecSpecific1 = longField(block, "mCodecSpecific1") ?: 0L,
            selectableCodecs = selectable,
        )
    }

    private fun intField(block: String, key: String): Int? =
        Regex("""$key:\s*(-?\d+)""").find(block)?.groupValues?.get(1)?.toIntOrNull()

    private fun longField(block: String, key: String): Long? =
        Regex("""$key:\s*(-?\d+)""").find(block)?.groupValues?.get(1)?.toLongOrNull()

    /** Mask fields print as `0x2(48000)` on most builds, plain decimal on a few. */
    private fun maskField(block: String, key: String): Int? {
        Regex("""$key:\s*0x([0-9a-fA-F]+)""").find(block)?.groupValues?.get(1)?.let {
            return it.toIntOrNull(16)
        }
        return intField(block, key)
    }
}
