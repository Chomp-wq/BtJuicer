package com.btjuicer.audio

import android.content.Context
import java.io.InputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

/**
 * One published correction for one headphone.
 *
 * [source] is who measured it and [rig] on what — both shown rather than hidden,
 * because two people measuring the same headphone on different rigs genuinely
 * disagree, and pretending there is a single answer would be the dishonest way
 * to present this.
 */
data class Headphone(
    val name: String,
    val source: String,
    val rig: String,
    val preampDb: Float,
    val filters: List<Filter>,
) {
    val label: String get() = "$source · $rig"
}

/** A model, with every measurement of it that the database carries. */
data class HeadphoneMatch(val name: String, val measurements: List<Headphone>) {
    /** The one applied unless the user picks another. */
    val preferred: Headphone get() = measurements.first()
}

/**
 * The bundled AutoEq database: 8850 corrections, searched off a single asset.
 *
 * ### What these curves are
 *
 * Each one is the difference between how that headphone actually measured and a
 * target curve derived from large listening-preference studies. That is worth
 * being precise about, because it decides what the feature is honestly allowed
 * to claim: this is not "a preset someone liked", it is a correction of a
 * measured deviation. It is also why there is no separate "best preset for every
 * genre" — the correction *is* the answer to that question, and a curve that
 * changed per genre would be undoing it.
 *
 * ### Why it scans the file instead of holding it
 *
 * Keeping all 8850 parsed would cost several megabytes of heap for the whole
 * life of the process to serve a search the user runs twice. Scanning the asset
 * takes a few tens of milliseconds and holds nothing between searches.
 *
 * From the AutoEq project by Jaakko Pasanen, MIT licensed. Measurements belong
 * to the people credited in [Headphone.source].
 */
class HeadphoneDb(private val open: () -> InputStream) {

    constructor(context: Context) : this({ context.assets.open(ASSET) })

    internal companion object {
        const val ASSET = "autoeq.tsv"
        const val MAX_RESULTS = 60

        /**
         * Who to believe first when several people measured the same model.
         *
         * Not a quality ranking so much as a consistency one: these are the
         * sources with the largest, most uniformly produced sets, so defaulting
         * to them makes results across different headphones comparable.
         */
        val SOURCE_RANK = listOf("oratory1990", "crinacle", "Rtings", "Innerfidelity")
    }

    suspend fun search(query: String): List<HeadphoneMatch> = withContext(Dispatchers.IO) {
        val needle = normalise(query)
        if (needle.isBlank()) return@withContext emptyList()
        val terms = needle.split(' ').filter { it.isNotEmpty() }

        val hits = mutableListOf<Pair<Int, Headphone>>()
        runCatching {
            open().bufferedReader().useLines { lines ->
                for (line in lines) {
                    val name = line.substringBefore('\t')
                    val score = score(normalise(name), terms) ?: continue
                    val entry = parse(line) ?: continue
                    hits += score to entry
                }
            }
        }.onFailure { return@withContext emptyList() }

        hits.groupBy { it.second.name }
            .map { (name, group) ->
                HeadphoneMatch(
                    name = name,
                    measurements = group.map { it.second }.sortedBy { rankOf(it.source) },
                )
            }
            // Best textual score first, then alphabetically so the list is
            // stable between keystrokes instead of reshuffling.
            .sortedWith(
                compareBy(
                    { match -> hits.filter { it.second.name == match.name }.minOf { it.first } },
                    { it.name.lowercase(Locale.ROOT) },
                ),
            )
            .take(MAX_RESULTS)
    }

    /** Lower is better; null means no match. */
    private fun score(name: String, terms: List<String>): Int? {
        val joined = terms.joinToString(" ")
        if (terms.all { name.contains(it) }) {
            return when {
                name == joined -> 0
                name.startsWith(joined) -> 1
                name.contains(joined) -> 2
                // All the words are there but scattered — "sony xm4" finding
                // "Sony WF-1000XM4" is worth keeping, just not at the top.
                else -> 3
            }
        }

        // Second pass with the spaces squeezed out, because nobody agrees on
        // where they go in a model number. Without it "hd600" misses
        // "Sennheiser HD 600" — the exact headphone the person is holding.
        val tight = name.replace(" ", "")
        val tightNeedle = joined.replace(" ", "")
        if (tightNeedle.isNotEmpty() && tight.contains(tightNeedle)) {
            return if (tight.startsWith(tightNeedle)) 2 else 4
        }
        return null
    }

    private fun rankOf(source: String): Int =
        SOURCE_RANK.indexOfFirst { it.equals(source, ignoreCase = true) }
            .let { if (it < 0) SOURCE_RANK.size else it }

    /**
     * Folds case and strips accents and punctuation, so that "sennheiser hd600"
     * finds "Sennheiser HD 600" and an accented model name is reachable from a
     * keyboard that does not have the accent.
     */
    private fun normalise(text: String): String {
        val builder = StringBuilder(text.length)
        var lastWasSpace = true
        for (raw in java.text.Normalizer.normalize(text, java.text.Normalizer.Form.NFD)) {
            val c = raw.lowercaseChar()
            when {
                c.isLetterOrDigit() && c.code < 0x300 -> {
                    builder.append(c)
                    lastWasSpace = false
                }
                // Combining accents land in this range after NFD; drop them.
                c.code in 0x300..0x36F -> Unit
                !lastWasSpace -> {
                    builder.append(' ')
                    lastWasSpace = true
                }
            }
        }
        return builder.toString().trim()
    }

    /** `name \t source \t rig \t preamp \t TYPE:fc:gain:q|…` */
    private fun parse(line: String): Headphone? {
        val parts = line.split('\t')
        if (parts.size < 5) return null
        val filters = parts[4].split('|').mapNotNull { spec ->
            val f = spec.split(':')
            if (f.size < 4) return@mapNotNull null
            Filter(
                type = when (f[0]) {
                    "LSC" -> FilterType.LOW_SHELF
                    "HSC" -> FilterType.HIGH_SHELF
                    "PK" -> FilterType.PEAKING
                    else -> return@mapNotNull null
                },
                freqHz = f[1].toFloatOrNull() ?: return@mapNotNull null,
                gainDb = f[2].toFloatOrNull() ?: return@mapNotNull null,
                q = f[3].toFloatOrNull() ?: return@mapNotNull null,
            )
        }
        if (filters.isEmpty()) return null
        return Headphone(
            name = parts[0],
            source = parts[1],
            rig = parts[2],
            preampDb = parts[3].toFloatOrNull() ?: 0f,
            filters = filters,
        )
    }
}
