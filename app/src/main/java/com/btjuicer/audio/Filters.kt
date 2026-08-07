package com.btjuicer.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.roundToInt

/**
 * Parametric filters and the maths to turn them into a curve.
 *
 * The app's model of an equaliser is a list of biquads — the same thing AutoEq
 * publishes, and the same thing every desktop parametric EQ speaks. Android's
 * `DynamicsProcessing` does not take biquads; it takes a bank of bands with a
 * gain each. So we evaluate the filters' combined magnitude response at each
 * band centre and hand over those numbers.
 *
 * That makes the result an approximation of the ideal cascade, and it is worth
 * being clear about it: the filterbank cannot reproduce a very narrow, very deep
 * notch. Broad tonal shaping — which is what actually changes how a headphone
 * sounds — comes through faithfully.
 */
enum class FilterType(val code: String, val label: String) {
    PEAKING("PK", "Campana"),
    LOW_SHELF("LSC", "Shelf grave"),
    HIGH_SHELF("HSC", "Shelf agudo"),
    LOW_PASS("LP", "Paso bajo"),
    HIGH_PASS("HP", "Paso alto"),
    ;

    /** True when the filter's gain has no meaning (pass filters just cut). */
    val usesGain: Boolean get() = this == PEAKING || this == LOW_SHELF || this == HIGH_SHELF
}

data class Filter(
    val type: FilterType = FilterType.PEAKING,
    val enabled: Boolean = true,
    val freqHz: Float = 1_000f,
    val gainDb: Float = 0f,
    val q: Float = 1f,
) {
    fun describe(): String = buildString {
        append(type.label)
        append(" · ")
        append(formatHz(freqHz))
        if (type.usesGain) append(" · %+.1f dB".format(gainDb))
        append(" · Q %.2f".format(q))
    }
}

fun formatHz(hz: Float): String =
    if (hz >= 1000f) "%.2f kHz".format(hz / 1000f).replace(".00", "") else "%.0f Hz".format(hz)

/**
 * Biquad coefficients from the Audio EQ Cookbook, and the closed-form magnitude
 * of the resulting transfer function.
 */
object Biquad {

    private const val DEFAULT_SAMPLE_RATE = 48_000f

    private data class Coeffs(
        val b0: Double,
        val b1: Double,
        val b2: Double,
        val a0: Double,
        val a1: Double,
        val a2: Double,
    )

    fun magnitudeDb(filter: Filter, atHz: Float, sampleRate: Float = DEFAULT_SAMPLE_RATE): Float {
        if (!filter.enabled) return 0f
        if (filter.type.usesGain && filter.gainDb == 0f) return 0f

        val nyquist = sampleRate / 2f
        if (filter.freqHz <= 0f || filter.freqHz >= nyquist) return 0f
        if (atHz <= 0f || atHz >= nyquist) return 0f

        val c = coefficients(filter, sampleRate)

        // |H(e^jw)|^2 in terms of phi = sin^2(w/2); avoids complex arithmetic and
        // is numerically well behaved right down to 20 Hz.
        val w = 2.0 * PI * atHz / sampleRate
        val phi = sin(w / 2.0).pow(2.0)

        val num = (c.b0 + c.b1 + c.b2).pow(2.0) -
            4.0 * (c.b0 * c.b1 + 4.0 * c.b0 * c.b2 + c.b1 * c.b2) * phi +
            16.0 * c.b0 * c.b2 * phi * phi
        val den = (c.a0 + c.a1 + c.a2).pow(2.0) -
            4.0 * (c.a0 * c.a1 + 4.0 * c.a0 * c.a2 + c.a1 * c.a2) * phi +
            16.0 * c.a0 * c.a2 * phi * phi

        if (den <= 0.0 || num < 0.0) return 0f
        val magnitudeSquared = num / den
        if (magnitudeSquared <= 0.0) return -120f
        return (10.0 * log10(magnitudeSquared)).toFloat()
    }

    private fun coefficients(filter: Filter, sampleRate: Float): Coeffs {
        val w0 = 2.0 * PI * filter.freqHz / sampleRate
        val cosW0 = cos(w0)
        val sinW0 = sin(w0)
        val q = filter.q.coerceAtLeast(0.05f).toDouble()
        val alpha = sinW0 / (2.0 * q)
        val a = 10.0.pow(filter.gainDb / 40.0)
        val sqrtA = sqrt(a)

        return when (filter.type) {
            FilterType.PEAKING -> Coeffs(
                b0 = 1 + alpha * a,
                b1 = -2 * cosW0,
                b2 = 1 - alpha * a,
                a0 = 1 + alpha / a,
                a1 = -2 * cosW0,
                a2 = 1 - alpha / a,
            )

            FilterType.LOW_SHELF -> Coeffs(
                b0 = a * ((a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha),
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW0),
                b2 = a * ((a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha),
                a0 = (a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha,
                a1 = -2 * ((a - 1) + (a + 1) * cosW0),
                a2 = (a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha,
            )

            FilterType.HIGH_SHELF -> Coeffs(
                b0 = a * ((a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha),
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW0),
                b2 = a * ((a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha),
                a0 = (a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha,
                a1 = 2 * ((a - 1) - (a + 1) * cosW0),
                a2 = (a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha,
            )

            FilterType.LOW_PASS -> Coeffs(
                b0 = (1 - cosW0) / 2,
                b1 = 1 - cosW0,
                b2 = (1 - cosW0) / 2,
                a0 = 1 + alpha,
                a1 = -2 * cosW0,
                a2 = 1 - alpha,
            )

            FilterType.HIGH_PASS -> Coeffs(
                b0 = (1 + cosW0) / 2,
                b1 = -(1 + cosW0),
                b2 = (1 + cosW0) / 2,
                a0 = 1 + alpha,
                a1 = -2 * cosW0,
                a2 = 1 - alpha,
            )
        }
    }
}

object Curve {

    /**
     * ISO third-octave centres, 20 Hz to 20 kHz. Thirty-one points is enough to
     * follow a headphone correction closely while staying inside what phone
     * audio HALs will accept as a band count.
     */
    val THIRD_OCTAVE: List<Int> = listOf(
        20, 25, 32, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1_000, 1_250, 1_600,
        2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000,
        20_000,
    )

    /** Ten octave centres, for the simple slider view. */
    val OCTAVE: List<Int> = listOf(31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000)

    /**
     * Band centres at [perOctave] per octave, 20 Hz to 20 kHz.
     *
     * Distinct integers only: at twelfth-octave the spacing down at 20 Hz is
     * about 1.2 Hz, so rounding to whole hertz would otherwise produce repeats —
     * and a band bank with two bands on the same frequency is a band bank the
     * audio HAL is entitled to refuse.
     */
    fun bands(perOctave: Int): List<Int> = buildList {
        var step = 0
        while (true) {
            val hz = (20.0 * 2.0.pow(step.toDouble() / perOctave)).roundToInt()
            if (hz > 20_000) break
            if (lastOrNull() != hz) add(hz)
            step++
        }
    }

    /**
     * Q for the simple view's bands. One octave of bandwidth works out near
     * 1.41; wider than that and neighbouring sliders fight each other, narrower
     * and the curve between sliders sags.
     */
    const val OCTAVE_Q = 1.41f

    fun simpleFilters(gainsDb: List<Float>): List<Filter> =
        OCTAVE.mapIndexed { index, hz ->
            Filter(
                type = FilterType.PEAKING,
                enabled = true,
                freqHz = hz.toFloat(),
                gainDb = gainsDb.getOrElse(index) { 0f },
                q = OCTAVE_Q,
            )
        }

    /** Combined response of [filters] at each frequency in [points]. */
    fun render(
        filters: List<Filter>,
        points: List<Int> = THIRD_OCTAVE,
        sampleRate: Float = 48_000f,
    ): List<Float> = points.map { hz ->
        filters.sumOf { Biquad.magnitudeDb(it, hz.toFloat(), sampleRate).toDouble() }.toFloat()
    }

    /**
     * Response sampled on a log frequency axis, for drawing. Returns pairs of
     * (Hz, dB) so the caller does not have to know the spacing.
     */
    fun forPlot(
        filters: List<Filter>,
        resolution: Int = 160,
        fromHz: Float = 20f,
        toHz: Float = 20_000f,
        sampleRate: Float = 48_000f,
    ): List<Pair<Float, Float>> {
        val logFrom = ln(fromHz.toDouble())
        val logTo = ln(toHz.toDouble())
        return (0 until resolution).map { i ->
            val hz = kotlin.math.exp(logFrom + (logTo - logFrom) * i / (resolution - 1.0)).toFloat()
            val db = filters.sumOf { Biquad.magnitudeDb(it, hz, sampleRate).toDouble() }.toFloat()
            hz to db
        }
    }

    /**
     * Solves for the band gains whose *combined* response matches [targetDb].
     *
     * Naively copying a target curve into a bank of peaking filters overshoots,
     * because neighbouring bands each still contribute a good fraction of their
     * gain at the next band's centre — ask for +3 dB across a region and you get
     * +5. This walks the gains down until the summed response lands on the
     * target, which is what makes a slider labelled "+6 dB at 125 Hz" actually
     * mean +6 dB at 125 Hz.
     *
     * Damped fixed-point iteration: cheap, monotonic in practice, and it
     * converges in far fewer rounds than the cap.
     */
    fun fitPeakingGains(
        targetDb: List<Float>,
        points: List<Int>,
        q: Float,
        sampleRate: Float = 48_000f,
        iterations: Int = 24,
        damping: Float = 0.7f,
    ): List<Float> {
        val gains = FloatArray(points.size) { targetDb.getOrElse(it) { 0f } }
        repeat(iterations) {
            val filters = points.mapIndexed { i, hz ->
                Filter(FilterType.PEAKING, true, hz.toFloat(), gains[i], q)
            }
            val response = render(filters, points, sampleRate)
            var worst = 0f
            for (i in gains.indices) {
                val error = targetDb.getOrElse(i) { 0f } - response[i]
                if (kotlin.math.abs(error) > worst) worst = kotlin.math.abs(error)
                gains[i] = (gains[i] + error * damping).coerceIn(-24f, 24f)
            }
            if (worst < 0.05f) return gains.toList()
        }
        return gains.toList()
    }

    /** Peaking filters that realise [targetDb] at [points]. */
    fun fittedFilters(
        targetDb: List<Float>,
        points: List<Int>,
        q: Float,
        sampleRate: Float = 48_000f,
    ): List<Filter> {
        val gains = fitPeakingGains(targetDb, points, q, sampleRate)
        return points.mapIndexed { i, hz ->
            Filter(FilterType.PEAKING, true, hz.toFloat(), gains[i], q)
        }
    }

    /** The preamp that keeps the loudest boost from clipping what follows. */
    fun suggestedPreamp(filters: List<Filter>): Float {
        val peak = render(filters).maxOrNull() ?: 0f
        return if (peak <= 0f) 0f else -peak
    }
}
