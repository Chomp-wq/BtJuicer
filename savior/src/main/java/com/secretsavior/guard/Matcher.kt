package com.secretsavior.guard

import java.text.Normalizer
import java.util.Arrays

/**
 * Plegado de texto compartido por los patrones y por lo que se lee en pantalla. Sin Android.
 *
 * Minúsculas, sin marcas combinables (acentos, vocales árabes/hebreas, nukta...) y sin nada que
 * no sea letra o dígito: espacios (incluido el no separable), guiones, apóstrofos y signos. Así
 * «Forcer l’arrêt», «forcer l'arret» y «FORCER L'ARRÊT» son lo mismo, y «MIUI 版本» da igual
 * que «MIUI版本» (el chino no separa con espacios). Devuelve '\u0000' para ignorar un carácter.
 */
object Fold {
    private const val TABLE = 0x2000
    private val table = CharArray(TABLE) { compute(it.toChar()) }

    fun of(c: Char): Char = if (c.code < TABLE) table[c.code] else high(c)

    /** El texto entero plegado (para comparar títulos exactos). Reserva memoria: no usar por nodo. */
    fun normalize(s: CharSequence?): String {
        if (s == null) return ""
        val sb = StringBuilder(s.length)
        for (i in 0 until s.length) {
            val f = of(s[i])
            if (f != '\u0000') sb.append(f)
        }
        return sb.toString()
    }

    private fun skipType(type: Int): Boolean = when (type.toByte()) {
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.FORMAT, Character.CONTROL,
        Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
        Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION,
        Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION,
        -> true
        else -> false
    }

    private fun compute(c: Char): Char {
        if (c.code < 0x80) {
            return when (c) {
                in 'A'..'Z' -> c + 32
                in 'a'..'z', in '0'..'9' -> c
                else -> '\u0000'
            }
        }
        if (skipType(Character.getType(c))) return '\u0000'
        val lower = Character.toLowerCase(c)
        // La descomposición NFD quita acentos (é→e, й→и, ά→α, ệ→e, ज़→ज) y plega las formas de la
        // alef árabe con hamza. Sólo en las zonas donde hay letras acentuadas: los sílabos
        // coreanos o el kana no se tocan (descompuestos, colisionarían entre sí).
        val d = Normalizer.normalize(lower.toString(), Normalizer.Form.NFD)
        var base = lower
        for (ch in d) {
            if (Character.getType(ch) != Character.NON_SPACING_MARK.toInt()) {
                base = ch
                break
            }
        }
        return special(base)
    }

    private fun high(c: Char): Char {
        val code = c.code
        if (code in 0xFF01..0xFF5E) return of((code - 0xFEE0).toChar()) // latín de ancho completo
        if (skipType(Character.getType(c))) return '\u0000'
        return Character.toLowerCase(c)
    }

    /** Variantes que distintos teclados/idiomas escriben con otra letra pero son la misma. */
    private fun special(c: Char): Char = when (c) {
        'ς' -> 'σ' // sigma final -> sigma (en mayúsculas no se distinguen)
        'ı' -> 'i' // ı turca: «KALDIR» en mayúsculas lleva I, y «İ» baja a i
        'ى', 'ی' -> 'ي' // alef maksura y ye persa -> ye árabe
        'ک' -> 'ك' // ک -> ك
        'ة' -> 'ه' // ة -> ه
        else -> c
    }
}

/**
 * Autómata de Aho–Corasick: dado un texto, devuelve de una pasada la máscara de bits de los
 * conceptos cuyos patrones aparecen en él. Sin reservar memoria por llamada (el árbol se
 * construye una vez por idioma), y lo mismo con 20 patrones que con 2000.
 */
class Matcher(patterns: Collection<Pair<String, Int>>) {

    private val keys: Array<CharArray>
    private val next: Array<IntArray>
    private val fail: IntArray
    private val out: IntArray

    /** Cuántos nodos tiene el árbol (para tests y diagnóstico). */
    val size: Int get() = out.size

    init {
        val children = ArrayList<HashMap<Char, Int>>().apply { add(HashMap()) }
        val outs = ArrayList<Int>().apply { add(0) }
        for ((p, bit) in patterns) {
            var s = 0
            var any = false
            for (ch in p) {
                val f = Fold.of(ch)
                if (f == '\u0000') continue
                any = true
                val m = children[s]
                var t = m[f]
                if (t == null) {
                    t = children.size
                    children.add(HashMap())
                    outs.add(0)
                    m[f] = t
                }
                s = t
            }
            if (any) outs[s] = outs[s] or bit
        }
        val n = children.size
        fail = IntArray(n)
        out = IntArray(n) { outs[it] }
        val queue = ArrayDeque<Int>()
        for ((_, t) in children[0]) queue.add(t)
        while (queue.isNotEmpty()) {
            val s = queue.removeFirst()
            for ((ch, t) in children[s]) {
                var f = fail[s]
                while (f != 0 && !children[f].containsKey(ch)) f = fail[f]
                val ft = children[f][ch]
                fail[t] = if (ft != null && ft != t) ft else 0
                out[t] = out[t] or out[fail[t]]
                queue.add(t)
            }
        }
        keys = Array(n) { s -> children[s].keys.toCharArray().also { Arrays.sort(it) } }
        next = Array(n) { s -> IntArray(keys[s].size) { i -> children[s].getValue(keys[s][i]) } }
    }

    private fun edge(s: Int, c: Char): Int {
        val k = keys[s]
        if (k.isEmpty()) return -1
        val i = Arrays.binarySearch(k, c)
        return if (i >= 0) next[s][i] else -1
    }

    /** Máscara de conceptos hallados en [text]; 0 si no hay ninguno. */
    fun scan(text: CharSequence?): Int {
        if (text == null) return 0
        var s = 0
        var mask = 0
        for (i in 0 until text.length) {
            val f = Fold.of(text[i])
            if (f == '\u0000') continue
            var t = edge(s, f)
            while (t < 0 && s != 0) {
                s = fail[s]
                t = edge(s, f)
            }
            s = if (t >= 0) t else 0
            mask = mask or out[s]
        }
        return mask
    }
}
