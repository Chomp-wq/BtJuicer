package com.btjuicer.audio

import org.json.JSONArray
import org.json.JSONObject

const val MIN_GAIN_DB = -12f
const val MAX_GAIN_DB = 12f
const val MIN_PREAMP_DB = -20f
const val MAX_PREAMP_DB = 6f

/** Ten octave sliders, or a free list of biquads. Same engine underneath. */
enum class EqMode(val label: String) {
    SIMPLE("Sencillo"),
    PARAMETRIC("Paramétrico"),
}

/**
 * Multiband compression. Not a loudness trick: it lifts quiet passages without
 * touching the peaks, which is what makes music survive a noisy street without
 * riding the volume up and down.
 */
enum class MbcMode(val label: String, val note: String) {
    OFF("Desactivado", "Rango dinámico intacto. Lo correcto para escuchar en silencio."),
    GENTLE(
        "Suave",
        "Apenas un 2:1 en los tres rangos. Iguala discos con masterizaciones dispares.",
    ),
    STREET(
        "Calle",
        "Sube lo bajo bastante más. Para metro, autobús y calle, donde los pasajes suaves " +
            "desaparecen bajo el ruido.",
    ),
    NIGHT(
        "Noche",
        "Comprime fuerte y limita: escuchar a volumen muy bajo sin perder los detalles.",
    ),
}

data class EqConfig(
    val enabled: Boolean = false,
    val mode: EqMode = EqMode.SIMPLE,
    /** Target dB at each octave centre, for the simple view. */
    val bandsDb: List<Float> = List(Curve.OCTAVE.size) { 0f },
    /** Free biquads, for the parametric view and for imports. */
    val filters: List<Filter> = emptyList(),
    val preampDb: Float = 0f,
    /**
     * On by default. Boosting raises peak level and everything downstream — the
     * Bluetooth encoder included — clips hard and ugly.
     */
    val limiterEnabled: Boolean = true,
    val mbc: MbcMode = MbcMode.OFF,
    val presetName: String = Presets.FLAT.label,
    /** Where the current curve came from, e.g. an AutoEq import. */
    val sourceLabel: String = "",
) {
    /**
     * The biquads actually in force.
     *
     * In simple mode the slider values are *targets*, not filter gains: the
     * gains are solved so that neighbouring bells stop adding up and a slider at
     * +6 dB really produces +6 dB.
     */
    fun activeFilters(): List<Filter> = when (mode) {
        EqMode.SIMPLE -> Curve.fittedFilters(bandsDb, Curve.OCTAVE, Curve.OCTAVE_Q)
        EqMode.PARAMETRIC -> filters
    }

    fun withBand(index: Int, targetDb: Float): EqConfig {
        val next = bandsDb.toMutableList()
        while (next.size < Curve.OCTAVE.size) next.add(0f)
        next[index] = targetDb.coerceIn(MIN_GAIN_DB, MAX_GAIN_DB)
        return copy(
            mode = EqMode.SIMPLE,
            bandsDb = next,
            presetName = Presets.CUSTOM_LABEL,
            sourceLabel = "",
        )
    }

    fun withFilters(next: List<Filter>, label: String = ""): EqConfig = copy(
        mode = EqMode.PARAMETRIC,
        filters = next,
        presetName = Presets.CUSTOM_LABEL,
        sourceLabel = label,
    )

    /** Preamp that offsets the loudest boost so enabling the EQ is not just "louder". */
    fun suggestedPreamp(): Float =
        Curve.suggestedPreamp(activeFilters()).coerceIn(MIN_PREAMP_DB, 0f)

    fun toJson(): JSONObject = JSONObject().apply {
        put("enabled", enabled)
        put("mode", mode.name)
        put("bands", JSONArray().also { arr -> bandsDb.forEach { arr.put(it.toDouble()) } })
        put(
            "filters",
            JSONArray().also { arr ->
                filters.forEach { f ->
                    arr.put(
                        JSONObject().apply {
                            put("type", f.type.name)
                            put("on", f.enabled)
                            put("hz", f.freqHz.toDouble())
                            put("gain", f.gainDb.toDouble())
                            put("q", f.q.toDouble())
                        },
                    )
                }
            },
        )
        put("preamp", preampDb.toDouble())
        put("limiter", limiterEnabled)
        put("mbc", mbc.name)
        put("preset", presetName)
        put("source", sourceLabel)
    }

    companion object {
        fun fromJson(json: JSONObject): EqConfig {
            val bandArray = json.optJSONArray("bands")
            val bands = List(Curve.OCTAVE.size) { i ->
                (bandArray?.optDouble(i, 0.0) ?: 0.0).toFloat()
            }

            val filterArray = json.optJSONArray("filters")
            val filters = buildList {
                for (i in 0 until (filterArray?.length() ?: 0)) {
                    val obj = filterArray?.optJSONObject(i) ?: continue
                    val type = runCatching { FilterType.valueOf(obj.optString("type")) }
                        .getOrDefault(FilterType.PEAKING)
                    add(
                        Filter(
                            type = type,
                            enabled = obj.optBoolean("on", true),
                            freqHz = obj.optDouble("hz", 1000.0).toFloat(),
                            gainDb = obj.optDouble("gain", 0.0).toFloat(),
                            q = obj.optDouble("q", 1.0).toFloat(),
                        ),
                    )
                }
            }

            return EqConfig(
                enabled = json.optBoolean("enabled", false),
                mode = runCatching { EqMode.valueOf(json.optString("mode")) }
                    .getOrDefault(EqMode.SIMPLE),
                bandsDb = bands,
                filters = filters,
                preampDb = json.optDouble("preamp", 0.0).toFloat(),
                limiterEnabled = json.optBoolean("limiter", true),
                mbc = runCatching { MbcMode.valueOf(json.optString("mbc")) }
                    .getOrDefault(MbcMode.OFF),
                presetName = json.optString("preset", Presets.FLAT.label),
                sourceLabel = json.optString("source", ""),
            )
        }
    }
}

data class Preset(val label: String, val note: String, val bandsDb: List<Float>)

/**
 * Starting points, not measured corrections. Nothing here is tuned to a specific
 * headphone — for that, import an AutoEq profile for your exact model, which is
 * a different order of accuracy.
 */
object Presets {

    const val CUSTOM_LABEL = "Personalizado"

    val FLAT = Preset(
        label = "Plano",
        note = "Sin alterar. El punto de partida para juzgar cualquier otro.",
        bandsDb = List(Curve.OCTAVE.size) { 0f },
    )

    val BASS = Preset(
        label = "Más graves",
        note = "Sube el sub-grave y deja limpio el medio, para que no embarre las voces.",
        bandsDb = listOf(6f, 5f, 3f, 1f, 0f, 0f, 0f, 0f, 0f, 0f),
    )

    val VOCAL = Preset(
        label = "Voz",
        note = "Realza el rango de la voz humana y recorta el grave que la tapa.",
        bandsDb = listOf(-3f, -2f, -1f, 0f, 2f, 3f, 3f, 1f, 0f, 0f),
    )

    val BRIGHT = Preset(
        label = "Brillo",
        note = "Aire y detalle arriba. Con cuidado: cansa en sesiones largas.",
        bandsDb = listOf(0f, 0f, 0f, 0f, 0f, 0f, 1f, 3f, 4f, 4f),
    )

    val SMILE = Preset(
        label = "Curva en V",
        note = "Graves y agudos arriba, medios abajo. Espectacular al principio, fatigoso después.",
        bandsDb = listOf(5f, 4f, 2f, 0f, -2f, -2f, 0f, 2f, 4f, 5f),
    )

    val WARM = Preset(
        label = "Cálido",
        note = "Baja el filo de 2–6 kHz. Ayuda con grabaciones estridentes y con la fatiga.",
        bandsDb = listOf(2f, 2f, 1f, 0f, 0f, -1f, -3f, -3f, -1f, 0f),
    )

    val ALL = listOf(FLAT, BASS, VOCAL, WARM, BRIGHT, SMILE)

    fun byLabel(label: String): Preset? = ALL.firstOrNull { it.label == label }
}
