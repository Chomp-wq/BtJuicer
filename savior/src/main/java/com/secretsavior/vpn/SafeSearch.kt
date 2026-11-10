package com.secretsavior.vpn

/**
 * Búsqueda segura forzada por DNS, sin depender del resolutor de turno. Los buscadores
 * enseñan miniaturas servidas desde sus propios servidores (DuckDuckGo las pasa por su
 * proxy), así que con la búsqueda segura apagada se ve contenido para adultos sin visitar
 * ningún dominio bloqueado. Cada buscador publica un nombre que la fuerza: aquí se decide
 * a cuál se desvía cada uno. Sin Android: lógica pura.
 *
 * YouTube queda fuera a propósito: su modo restringido esconde mucho contenido corriente.
 */
object SafeSearch {

    /** google.com y los dominios de país (google.es, google.com.mx, google.co.uk...). */
    private val GOOGLE = Regex("^(www\\.)?google\\.(com|[a-z]{2}|com?\\.[a-z]{2})$")
    private val YANDEX = Regex("^(www\\.)?(yandex\\.(ru|com|by|kz|uz|com\\.tr)|ya\\.ru)$")

    /** El nombre que hay que resolver en lugar de [rawName], o null si no es un buscador. */
    fun target(rawName: String): String? {
        val name = rawName.trimEnd('.').lowercase()
        return when {
            name == "duckduckgo.com" || name == "www.duckduckgo.com" || name == "start.duckduckgo.com" ->
                "safe.duckduckgo.com"
            name == "bing.com" || name == "www.bing.com" -> "strict.bing.com"
            "google." in name && GOOGLE.matches(name) -> "forcesafesearch.google.com"
            ("yandex." in name || name.endsWith("ya.ru")) && YANDEX.matches(name) -> "familysearch.yandex.ru"
            else -> null
        }
    }
}
