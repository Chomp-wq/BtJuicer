package com.btjuicer.audio

/**
 * A taste adjustment laid on top of a measured correction.
 *
 * The distinction between these and the correction underneath is the whole
 * point, and it is worth stating plainly rather than blurring: an AutoEq curve
 * fixes a *measured* deviation between a headphone and a preference target, and
 * that is the closest thing to an objectively defensible setting. What follows
 * is not that. These are preferences, and they are labelled as preferences.
 *
 * They are kept small on purpose — two or three decibels of gentle shelf. A
 * headphone that has just been corrected does not need rescuing, and anything
 * bigger would be undoing the correction rather than seasoning it.
 */
enum class Flavour(
    val label: String,
    val note: String,
    val extra: List<Filter>,
) {
    /**
     * No seasoning. Named for what it is: if there is such a thing as "the best
     * setting for all music" on a given headphone, this is it — not because it
     * flatters anything, but because it is the one derived from what thousands
     * of listeners preferred in blind comparisons.
     */
    REFERENCE(
        "Referencia",
        "La corrección tal cual, sin retoques. Lo más parecido que existe a «el mejor ajuste para todo».",
        emptyList(),
    ),

    WARM(
        "Más cuerpo",
        "Un escalón suave por debajo de 100 Hz. Da peso sin enturbiar las voces.",
        listOf(Filter(FilterType.LOW_SHELF, freqHz = 100f, gainDb = 3f, q = 0.7f)),
    ),

    SMOOTH(
        "Menos brillo",
        "Baja la zona donde vive la fatiga. Para sesiones largas o grabaciones duras.",
        listOf(Filter(FilterType.HIGH_SHELF, freqHz = 7_500f, gainDb = -2.5f, q = 0.7f)),
    ),

    VOCAL(
        "Voces al frente",
        "Despeja un poco el grave medio y adelanta la presencia. Para pop, folk y directos.",
        listOf(
            Filter(FilterType.PEAKING, freqHz = 250f, gainDb = -1.5f, q = 1f),
            Filter(FilterType.PEAKING, freqHz = 2_500f, gainDb = 1.5f, q = 1f),
        ),
    ),

    AIR(
        "Más aire",
        "Un escalón por encima de 10 kHz. Abre la escena; también saca la sibilancia si la hay.",
        listOf(Filter(FilterType.HIGH_SHELF, freqHz = 10_000f, gainDb = 2f, q = 0.7f)),
    ),
    ;

    companion object {
        fun fromName(name: String?): Flavour =
            entries.firstOrNull { it.name == name } ?: REFERENCE
    }
}
