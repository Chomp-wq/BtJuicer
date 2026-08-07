package com.btjuicer.audio

/**
 * Starting points for Bluetooth speakers.
 *
 * ### Why these are not like the headphone database
 *
 * There is no AutoEq for speakers, and the reason is not that nobody got around
 * to it. A headphone's response at your ear is very nearly the same as it was on
 * the measuring rig. A speaker's is not: below a few hundred hertz the room
 * decides, and the same speaker measures differently on a shelf, on a table, and
 * in a corner. A published curve for "the Echo" would be a curve for someone
 * else's kitchen.
 *
 * So these are not corrections and are not labelled as such. They are the two or
 * three things that are true of nearly every small powered speaker, applied
 * conservatively.
 *
 * ### What they actually do
 *
 * The high-pass is the one that earns its place, and it is the opposite of what
 * people reach for. A small speaker cannot produce 50 Hz; feeding it 50 Hz does
 * not make bass, it makes the driver flap and the built-in limiter clamp down on
 * *everything else*. Cutting what it cannot play makes the rest louder and
 * cleaner. Boosting bass on a small speaker reliably makes it worse.
 *
 * The rest is taming the midbass hump that manufacturers dial in for shop-floor
 * impressiveness, and giving back a little of the presence that hump masks.
 */
internal object SpeakerCurves {

    private const val SOURCE = "genérico · no medido"

    val ALL: List<Headphone> = listOf(
        speaker(
            name = "Altavoz Bluetooth pequeño",
            aliases = listOf("bocina", "speaker", "portatil", "jbl", "flip", "go", "soundlink"),
            filters = listOf(
                Filter(FilterType.HIGH_PASS, freqHz = 80f, q = 0.7f),
                Filter(FilterType.PEAKING, freqHz = 180f, gainDb = -3f, q = 1f),
                Filter(FilterType.PEAKING, freqHz = 3_000f, gainDb = 2f, q = 1f),
                Filter(FilterType.HIGH_SHELF, freqHz = 9_000f, gainDb = 2f, q = 0.7f),
            ),
        ),
        speaker(
            name = "Altavoz Bluetooth grande",
            aliases = listOf("bocina grande", "boombox", "charge", "xtreme", "partybox"),
            filters = listOf(
                Filter(FilterType.HIGH_PASS, freqHz = 45f, q = 0.7f),
                Filter(FilterType.PEAKING, freqHz = 150f, gainDb = -2f, q = 1f),
                Filter(FilterType.PEAKING, freqHz = 2_800f, gainDb = 1.5f, q = 1f),
                Filter(FilterType.HIGH_SHELF, freqHz = 10_000f, gainDb = 1.5f, q = 0.7f),
            ),
        ),
        speaker(
            name = "Amazon Echo / Alexa",
            aliases = listOf("alexa", "echo", "echo dot", "asistente"),
            filters = listOf(
                Filter(FilterType.HIGH_PASS, freqHz = 70f, q = 0.7f),
                // These ship with a deliberate midbass lift and a dip where
                // speech lives, which suits a voice assistant across a room and
                // not much else.
                Filter(FilterType.PEAKING, freqHz = 120f, gainDb = -3f, q = 1f),
                Filter(FilterType.PEAKING, freqHz = 2_500f, gainDb = 2.5f, q = 1.2f),
                Filter(FilterType.HIGH_SHELF, freqHz = 8_000f, gainDb = 2f, q = 0.7f),
            ),
        ),
        speaker(
            name = "Altavoz de portátil o tablet",
            aliases = listOf("laptop", "tablet", "monitor", "tele", "television"),
            filters = listOf(
                Filter(FilterType.HIGH_PASS, freqHz = 150f, q = 0.7f),
                Filter(FilterType.PEAKING, freqHz = 400f, gainDb = -3f, q = 1.2f),
                Filter(FilterType.PEAKING, freqHz = 3_000f, gainDb = 3f, q = 1f),
            ),
        ),
    )

    private fun speaker(name: String, aliases: List<String>, filters: List<Filter>) = Headphone(
        name = name,
        source = SOURCE,
        rig = "",
        // Computed from the curve rather than written by hand, so a later edit
        // to the filters cannot leave a preamp that no longer protects anything.
        preampDb = Curve.suggestedPreamp(filters),
        filters = filters,
        measured = false,
        aliases = aliases,
    )
}
