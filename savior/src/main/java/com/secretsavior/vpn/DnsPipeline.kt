package com.secretsavior.vpn

/**
 * Lo que se hace con una consulta DNS, venga por UDP o por TCP, del túnel propio o de una
 * dirección capturada (8.8.8.8...): canario, lista de bloqueo, búsqueda segura, caché y reenviador,
 * en ese orden. Sin Android: [onBlocked] cuenta los bloqueos y [forwarder] da el reenviador actual.
 *
 * [resolve] llama a `done` una sola vez, con la respuesta o con null si no hay nada que contestar
 * (consulta ilegible sin reenviador, o reenviador cerrado). Lo bloqueado se contesta aquí mismo,
 * sin salir del teléfono; lo demás no bloquea al hilo que llama.
 */
class DnsPipeline(
    private val forwarder: () -> DnsForwarder?,
    private val onBlocked: () -> Unit = {},
) {

    fun resolve(query: ByteArray, done: (ByteArray?) -> Unit) {
        val q = DnsPacket.parseQuestion(query)
        if (q != null) {
            if (DnsFilter.isCanary(q.name)) {
                done(DnsPacket.nxdomain(query, q))
                return
            }
            if (DnsFilter.isBlocked(q.name)) {
                if (q.type == DnsPacket.TYPE_A) onBlocked()
                done(DnsPacket.blocked(query, q))
                return
            }
            val safe = SafeSearch.target(q.name)
            if (safe != null) {
                safeSearch(query, q, safe, done)
                return
            }
        }
        val fwd = forwarder()
        if (fwd == null) {
            // No debería pasar; si pasa, un error al momento es mejor que 5 s de espera por consulta.
            done(q?.let { DnsPacket.servfail(query, it) })
            return
        }
        fwd.query(query) { response -> done(response ?: q?.let { DnsPacket.servfail(query, it) }) }
    }

    /**
     * Un buscador: se resuelve su nombre de búsqueda segura y se contesta con esas direcciones.
     * Los demás tipos de registro (HTTPS/SVCB, que podrían señalar a otros servidores) se
     * contestan vacíos. Si el nombre seguro no resuelve, falla: nunca el buscador sin filtrar.
     */
    private fun safeSearch(query: ByteArray, q: DnsPacket.Question, safe: String, done: (ByteArray?) -> Unit) {
        if (q.type != DnsPacket.TYPE_A && q.type != DnsPacket.TYPE_AAAA) {
            done(DnsPacket.blocked(query, q)) // sin registros
            return
        }
        val fwd = forwarder()
        if (fwd == null) {
            done(DnsPacket.servfail(query, q))
            return
        }
        fwd.query(DnsPacket.query(safe, q.type)) { response ->
            done(response?.let { DnsPacket.retarget(query, q, it) } ?: DnsPacket.servfail(query, q))
        }
    }
}
