package com.secretsavior.guard

import java.text.Normalizer

/**
 * Texto que se considera pornográfico al escribirlo o verlo en una barra de
 * direcciones. Sin Android: lógica pura. Nada de lo que pasa por aquí se guarda.
 */
object ContentRules {

    /**
     * Nombres de sitios y palabras que no significan otra cosa. Se vigila en
     * cualquier app.
     */
    private val strict = Regex(
        "\\b(porn\\w*|pornhub|xvideos?|xnxx|xhamster|redtube|youporn|chaturbate|onlyfans|hentai|rule34)\\b",
    )

    /**
     * Además, en navegadores —donde alguien está buscando, no hablando—, frases
     * que sólo tienen un sentido. "xxx" a solas se queda fuera de [strict]:
     * es como se firman los mensajes cariñosos.
     */
    private val search = Regex(
        "\\b(xxx|nsfw|milf|sex(o)?\\s+(video|videos|cam|cams|chat|gratis|free|tube|anal|oral|duro)|" +
            "(video|videos|fotos|imagenes)\\s+(de\\s+)?(sexo|xxx|porno)|" +
            "nudes?|desnud[ao]s?|naked\\s+(girls?|women|pics?)|tetas|follando|sex\\s*cams?)\\b",
    )

    /** [inBrowser] activa el conjunto ampliado. */
    fun isExplicit(text: CharSequence, inBrowser: Boolean): Boolean {
        if (text.isBlank()) return false
        val t = Normalizer.normalize(text.toString().lowercase(), Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
        if (strict.containsMatchIn(t)) return true
        return inBrowser && search.containsMatchIn(t)
    }
}
