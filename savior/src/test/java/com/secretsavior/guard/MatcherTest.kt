package com.secretsavior.guard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MatcherTest {

    private val A = 1
    private val B = 2
    private val C = 4
    private val D = 8

    @Test
    fun overlappingPatternsAllReported() {
        // El caso clásico de Aho–Corasick: «she» contiene a «he»; «hers» empieza por «he».
        val m = Matcher(listOf("he" to A, "she" to B, "his" to C, "hers" to D))
        assertEquals(A or B, m.scan("she"))
        assertEquals(A or D, m.scan("hers"))
        assertEquals(C, m.scan("his"))
        assertEquals(A or B or C or D, m.scan("ushers his"))
    }

    @Test
    fun noMatchIsZero() {
        val m = Matcher(listOf("force stop" to A))
        assertEquals(0, m.scan("Wi-Fi"))
        assertEquals(0, m.scan(""))
        assertEquals(0, m.scan(null))
    }

    @Test
    fun caseAndAccentsAreIgnored() {
        val m = Matcher(listOf("forcer l'arrêt" to A, "forzar detención" to B))
        assertEquals(A, m.scan("FORCER L’ARRÊT"))
        assertEquals(A, m.scan("forcer l arret"))
        assertEquals(B, m.scan("Forzar detencion"))
        assertEquals(B, m.scan("FORZAR DETENCIÓN"))
    }

    @Test
    fun spacesAndPunctuationDoNotMatter() {
        // El chino no separa con espacios y los fabricantes mezclan «MIUI 版本» con «MIUI版本».
        val m = Matcher(listOf("miui 版本" to A, "build number" to B))
        assertEquals(A, m.scan("MIUI版本"))
        assertEquals(A, m.scan("MIUI  版本"))
        assertEquals(B, m.scan("Build number"))
        assertEquals(B, m.scan("build-number"))
    }

    @Test
    fun foundInsideLongText() {
        val m = Matcher(listOf("uninstall" to A))
        assertEquals(A, m.scan("Do you want to uninstall this app?"))
    }

    @Test
    fun combiningMarksAreStripped() {
        val m = Matcher(listOf("accessibilité" to A))
        assertEquals(A, m.scan("Accessibilité")) // e + acento combinable
        assertEquals(A, m.scan("ACCESSIBILITÉ"))
    }

    @Test
    fun nonLatinScriptsMatch() {
        val m = Matcher(
            listOf(
                "强行停止" to A, "강제 중지" to B, "Принудительно остановить" to C, "फोर्स स्टॉप" to D,
            ),
        )
        assertEquals(A, m.scan("强行停止"))
        assertEquals(B, m.scan("강제 중지"))
        assertEquals(C, m.scan("принудительно ОСТАНОВИТЬ"))
        assertEquals(D, m.scan("फोर्स स्टॉप"))
    }

    @Test
    fun cyrillicYoAndHebrewNiqqudFold() {
        val m = Matcher(listOf("ещё" to A, "שלום" to B))
        assertEquals(A, m.scan("еще"))
        assertEquals(B, m.scan("שָׁלוֹם"))
    }

    @Test
    fun arabicHamzaVariantsFold() {
        val m = Matcher(listOf("إيقاف" to A))
        assertEquals(A, m.scan("ايقاف"))
        assertEquals(A, m.scan("أيقاف"))
    }

    @Test
    fun manyPatternsStayFast() {
        val pats = (0 until 3000).map { "pattern number $it x" to 1 }
        val m = Matcher(pats)
        assertTrue(m.size > 1000)
        assertEquals(1, m.scan("a pattern number 2999 x b"))
        assertEquals(0, m.scan("pattern number 3000 y"))
    }
}
