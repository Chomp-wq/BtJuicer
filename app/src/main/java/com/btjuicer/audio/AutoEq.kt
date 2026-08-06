package com.btjuicer.audio

import kotlin.math.ln

/**
 * Reads the two text formats the AutoEq project publishes.
 *
 * AutoEq measures real headphones and computes the correction that brings them
 * to a target curve. Importing one is the difference between "I moved sliders
 * until it sounded nicer" and a correction someone derived from a measurement of
 * your exact model — by a wide margin the biggest single improvement available
 * to an equaliser, and the reason this parser exists.
 *
 * Nothing here is network-bound: the user pastes the text or picks the file. The
 * app ships no measurement data of its own and makes no claim about any
 * particular headphone.
 */
object AutoEq {

    /** Matches third-octave spacing: bandwidth 1/3 octave gives Q ≈ 4.32. */
    private const val THIRD_OCTAVE_Q = 4.32f

    data class Import(
        val filters: List<Filter>,
        val preampDb: Float?,
        val sourceLabel: String,
    )

    /** `Filter 3: ON PK Fc 105 Hz Gain -2.6 dB Q 0.70` */
    private val PARAMETRIC_LINE = Regex(
        """^\s*Filter\s+\d+\s*:\s*(ON|OFF)\s+([A-Za-z]+)\s+Fc\s+([\d.]+)\s*Hz""" +
            """(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?""",
        RegexOption.IGNORE_CASE,
    )

    private val PREAMP_LINE = Regex("""^\s*Preamp\s*:\s*(-?[\d.]+)\s*dB""", RegexOption.IGNORE_CASE)

    private val GRAPHIC_LINE = Regex("""GraphicEQ\s*:\s*(.+)""", RegexOption.IGNORE_CASE)

    fun parse(text: String): Result<Import> {
        if (text.isBlank()) return Result.failure(IllegalArgumentException("El texto está vacío"))

        GRAPHIC_LINE.find(text)?.let { match ->
            return parseGraphic(match.groupValues[1])
        }

        val filters = mutableListOf<Filter>()
        var preamp: Float? = null

        text.lineSequence().forEach { line ->
            PREAMP_LINE.find(line)?.let { preamp = it.groupValues[1].toFloatOrNull() }
            PARAMETRIC_LINE.find(line)?.let { match ->
                val enabled = match.groupValues[1].equals("ON", ignoreCase = true)
                val type = typeOf(match.groupValues[2]) ?: return@let
                val freq = match.groupValues[3].toFloatOrNull() ?: return@let
                val gain = match.groupValues[4].toFloatOrNull() ?: 0f
                // A missing Q is legal for shelves in some exports; 0.707 is the
                // value AutoEq itself uses as default.
                val q = match.groupValues[5].toFloatOrNull() ?: 0.707f
                filters += Filter(type, enabled, freq, gain, q)
            }
        }

        if (filters.isEmpty()) {
            return Result.failure(
                IllegalArgumentException(
                    "No se reconoció ningún filtro. Pega el contenido de un archivo " +
                        "«ParametricEQ.txt» o «GraphicEQ.txt» de AutoEq.",
                ),
            )
        }

        return Result.success(
            Import(
                filters = filters,
                preampDb = preamp,
                sourceLabel = "AutoEq · ${filters.size} filtros",
            ),
        )
    }

    private fun typeOf(code: String): FilterType? = when (code.uppercase()) {
        "PK", "PEQ", "MODAL" -> FilterType.PEAKING
        "LS", "LSC", "LSQ", "LOWSHELF" -> FilterType.LOW_SHELF
        "HS", "HSC", "HSQ", "HIGHSHELF" -> FilterType.HIGH_SHELF
        "LP", "LPQ" -> FilterType.LOW_PASS
        "HP", "HPQ" -> FilterType.HIGH_PASS
        else -> null
    }

    /**
     * `GraphicEQ: 20 -0.5; 21 -0.6; …` — a dense target curve rather than
     * filters. Resampled onto our band centres and turned into one peaking
     * filter per band, which is the only shape the engine can actually apply.
     */
    private fun parseGraphic(payload: String): Result<Import> {
        val points = payload.split(';').mapNotNull { entry ->
            val parts = entry.trim().split(Regex("\\s+"))
            if (parts.size < 2) return@mapNotNull null
            val hz = parts[0].toFloatOrNull() ?: return@mapNotNull null
            val db = parts[1].toFloatOrNull() ?: return@mapNotNull null
            hz to db
        }.sortedBy { it.first }

        if (points.size < 4) {
            return Result.failure(IllegalArgumentException("La curva GraphicEQ no tiene suficientes puntos"))
        }

        // Solved rather than copied: adjacent third-octave bells overlap, so
        // pasting the target straight in overshoots by several dB.
        val target = Curve.THIRD_OCTAVE.map { interpolateLog(points, it.toFloat()) }
        val filters = Curve.fittedFilters(target, Curve.THIRD_OCTAVE, THIRD_OCTAVE_Q)
            .filter { kotlin.math.abs(it.gainDb) > 0.05f }

        return Result.success(
            Import(
                filters = filters,
                preampDb = null,
                sourceLabel = "AutoEq GraphicEQ · ${points.size} puntos",
            ),
        )
    }

    /** Linear interpolation on a log frequency axis, which is how we hear. */
    private fun interpolateLog(points: List<Pair<Float, Float>>, hz: Float): Float {
        if (hz <= points.first().first) return points.first().second
        if (hz >= points.last().first) return points.last().second

        val index = points.indexOfFirst { it.first >= hz }
        if (index <= 0) return points.first().second

        val (loHz, loDb) = points[index - 1]
        val (hiHz, hiDb) = points[index]
        if (hiHz <= loHz) return loDb

        val t = (ln(hz.toDouble()) - ln(loHz.toDouble())) / (ln(hiHz.toDouble()) - ln(loHz.toDouble()))
        return (loDb + (hiDb - loDb) * t).toFloat()
    }
}
