package com.secretsavior.guard

/**
 * Barra de direcciones de un navegador que no está en la lista de ids conocidos. Sin Android:
 * la búsqueda recorre un número acotado de nodos y pregunta a esto por cada id.
 */
object UrlBar {

    private val HINTS = listOf("url", "omnibox", "address", "location_bar")

    /** ¿El id de la vista («pkg:id/nombre») parece el de una barra de direcciones? */
    fun isUrlBarId(id: String?): Boolean {
        if (id.isNullOrEmpty()) return false
        val name = id.substringAfter('/')
        for (h in HINTS) if (Labels.containsIc(name, h)) return true
        return false
    }
}
