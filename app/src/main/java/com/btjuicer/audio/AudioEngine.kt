package com.btjuicer.audio

import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Backend { DYNAMICS, LEGACY }

sealed interface EngineState {
    data object Off : EngineState

    data class Active(
        val backend: Backend,
        val bandCount: Int,
        val mbcActive: Boolean,
    ) : EngineState

    data class Failed(val reason: String) : EngineState
}

/**
 * The equaliser itself.
 *
 * Attaches to audio session 0 — the global output mix — so it shapes whatever
 * the phone is playing, including apps whose audio can never be touched
 * directly, like the DRM-protected streaming services. No privileged access
 * involved: `MODIFY_AUDIO_SETTINGS` is a normal permission.
 *
 * Note where this sits in the chain: the EQ runs *before* the Bluetooth encoder,
 * which is exactly right for equalisation, and exactly why no DSP here can undo
 * what a lossy codec does afterwards.
 */
class AudioEngine {

    private companion object {
        const val TAG = "BTJuicer"

        /** Session 0 is the global output mix rather than one app's stream. */
        const val GLOBAL_SESSION = 0
        const val PRIORITY = 0

        /**
         * Band layouts to try, richest first. Some audio HALs cap the band count
         * and simply refuse to build the effect, so falling back is the
         * difference between a coarse equaliser and none at all.
         */
        val LAYOUTS: List<List<Int>> = listOf(
            Curve.THIRD_OCTAVE,
            Curve.THIRD_OCTAVE.filterIndexed { i, _ -> i % 2 == 0 },
            Curve.OCTAVE,
        )

        /** Crossovers for the three compressor bands. */
        val MBC_BANDS = listOf(120f, 2_000f, 8_000f)
    }

    private val lock = Any()

    private val _state = MutableStateFlow<EngineState>(EngineState.Off)
    val state: StateFlow<EngineState> = _state.asStateFlow()

    private var dynamics: DynamicsProcessing? = null
    private var dynamicsPoints: List<Int> = Curve.THIRD_OCTAVE
    private var legacy: Equalizer? = null

    /**
     * Idempotent: call whenever the config changes, and also whenever the audio
     * route changes — several ROMs quietly detach global-session effects when
     * the output switches between speaker and Bluetooth.
     */
    fun apply(config: EqConfig) {
        synchronized(lock) {
            if (!config.enabled) {
                releaseLocked()
                _state.value = EngineState.Off
                return
            }

            val filters = config.activeFilters()
            if (applyDynamics(config, filters)) return
            if (applyLegacy(config, filters)) return

            releaseLocked()
            _state.value = EngineState.Failed(
                "El sistema rechazó el ecualizador global. Suele pasar cuando otra app de audio " +
                    "ya lo tiene tomado, o cuando la ROM lo bloquea.",
            )
        }
    }

    fun release() {
        synchronized(lock) {
            releaseLocked()
            _state.value = EngineState.Off
        }
    }

    // -------------------------------------------------------------- dynamics

    private fun applyDynamics(config: EqConfig, filters: List<Filter>): Boolean {
        val engine = dynamics ?: createDynamics() ?: return false
        val points = dynamicsPoints

        return runCatching {
            val gains = Curve.render(filters, points)

            val eq = DynamicsProcessing.Eq(true, true, points.size)
            points.forEachIndexed { index, hz ->
                val gain = gains.getOrElse(index) { 0f }.coerceIn(-24f, 24f)
                eq.setBand(index, DynamicsProcessing.EqBand(true, hz.toFloat(), gain))
            }
            engine.setPreEqAllChannelsTo(eq)

            engine.setInputGainAllChannelsTo(config.preampDb.coerceIn(MIN_PREAMP_DB, MAX_PREAMP_DB))
            applyMbc(engine, config.mbc)

            engine.setLimiterAllChannelsTo(
                DynamicsProcessing.Limiter(
                    /* inUse = */ true,
                    /* enabled = */ config.limiterEnabled,
                    /* linkGroup = */ 0,
                    /* attackTime = */ 1f,
                    /* releaseTime = */ 60f,
                    /* ratio = */ 10f,
                    /* threshold = */ -1f,
                    /* postGain = */ 0f,
                ),
            )

            engine.enabled = true
            _state.value = EngineState.Active(Backend.DYNAMICS, points.size, config.mbc != MbcMode.OFF)
            true
        }.getOrElse {
            Log.w(TAG, "DynamicsProcessing failed", it)
            releaseDynamics()
            false
        }
    }

    private fun applyMbc(engine: DynamicsProcessing, mode: MbcMode) {
        runCatching {
            val mbc = DynamicsProcessing.Mbc(true, mode != MbcMode.OFF, MBC_BANDS.size)
            MBC_BANDS.forEachIndexed { index, hz ->
                mbc.setBand(index, mbcBand(hz, mode, index))
            }
            engine.setMbcAllChannelsTo(mbc)
        }.onFailure { Log.w(TAG, "MBC unavailable", it) }
    }

    /**
     * Ratios rise and thresholds drop as the mode gets more aggressive. The low
     * band always gets the gentlest treatment: squashing bass is the fastest way
     * to make music sound small.
     */
    private fun mbcBand(hz: Float, mode: MbcMode, index: Int): DynamicsProcessing.MbcBand {
        val (ratio, threshold) = when (mode) {
            MbcMode.OFF -> 1f to 0f
            MbcMode.GENTLE -> 2f to -24f
            MbcMode.STREET -> 4f to -34f
            MbcMode.NIGHT -> 6f to -42f
        }
        val bandRatio = if (index == 0) (1f + (ratio - 1f) * 0.6f) else ratio

        return DynamicsProcessing.MbcBand(
            /* enabled = */ mode != MbcMode.OFF,
            /* cutoffFrequency = */ hz,
            /* attackTime = */ if (index == 0) 30f else 12f,
            /* releaseTime = */ if (index == 0) 250f else 150f,
            /* ratio = */ bandRatio,
            /* threshold = */ threshold,
            /* kneeWidth = */ 6f,
            /* noiseGateThreshold = */ -90f,
            /* expanderRatio = */ 1f,
            /* preGain = */ 0f,
            // Make-up gain: without it, compressing only ever makes things
            // quieter and the mode looks like it does nothing good.
            /* postGain = */ if (mode == MbcMode.OFF) 0f else -threshold * 0.35f,
        )
    }

    private fun createDynamics(): DynamicsProcessing? {
        for (points in LAYOUTS) {
            val built = runCatching {
                val config = DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                    /* channelCount = */ 2,
                    /* preEqInUse = */ true,
                    /* preEqBandCount = */ points.size,
                    /* mbcInUse = */ true,
                    /* mbcBandCount = */ MBC_BANDS.size,
                    /* postEqInUse = */ false,
                    /* postEqBandCount = */ 0,
                    /* limiterInUse = */ true,
                ).setPreferredFrameDuration(10f).build()

                DynamicsProcessing(PRIORITY, GLOBAL_SESSION, config)
            }.getOrElse {
                Log.w(TAG, "DynamicsProcessing rejected ${points.size} bands", it)
                null
            }

            if (built != null) {
                dynamics = built
                dynamicsPoints = points
                return built
            }
        }
        return null
    }

    // ---------------------------------------------------------------- legacy

    /**
     * Fallback for devices whose audio HAL refuses DynamicsProcessing. The
     * classic Equalizer offers whatever band count it feels like — usually five
     * — so the curve is simply evaluated at those centres.
     */
    private fun applyLegacy(config: EqConfig, filters: List<Filter>): Boolean {
        val eq = legacy ?: runCatching { Equalizer(PRIORITY, GLOBAL_SESSION).also { legacy = it } }
            .getOrElse {
                Log.w(TAG, "Equalizer unavailable", it)
                return false
            }

        return runCatching {
            val range = eq.bandLevelRange
            val minMb = range[0].toInt()
            val maxMb = range[1].toInt()

            for (band in 0 until eq.numberOfBands) {
                val centreHz = eq.getCenterFreq(band.toShort()) / 1000
                val gainDb = Curve.render(filters, listOf(centreHz))[0] + config.preampDb
                val millibels = (gainDb * 100f).toInt().coerceIn(minMb, maxMb)
                eq.setBandLevel(band.toShort(), millibels.toShort())
            }
            eq.enabled = true
            _state.value = EngineState.Active(Backend.LEGACY, eq.numberOfBands.toInt(), false)
            true
        }.getOrElse {
            Log.w(TAG, "Equalizer failed", it)
            releaseLegacy()
            false
        }
    }

    // -------------------------------------------------------------- teardown

    private fun releaseLocked() {
        releaseDynamics()
        releaseLegacy()
    }

    private fun releaseDynamics() {
        runCatching {
            dynamics?.enabled = false
            dynamics?.release()
        }
        dynamics = null
    }

    private fun releaseLegacy() {
        runCatching {
            legacy?.enabled = false
            legacy?.release()
        }
        legacy = null
    }
}
