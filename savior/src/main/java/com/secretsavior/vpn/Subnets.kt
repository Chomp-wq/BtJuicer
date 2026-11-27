package com.secretsavior.vpn

/**
 * El túnel necesita una subred propia para su "servidor DNS" falso. Si esa subred coincide con la
 * de la red real (el Wi-Fi de casa, la del operador), el teléfono deja de alcanzar a su propio
 * router. Se elige la primera de [CANDIDATES] que no se pisa con ninguna red en uso. Sin Android.
 */
object Subnets {

    class Candidate(private val prefix: String) {
        /** Dirección de la red, para la ruta. */
        val network = "$prefix.0"

        /** El teléfono dentro del túnel. */
        val address = "$prefix.2"

        /** El "servidor DNS": lo que se anuncia a las apps y a lo que escucha el túnel. */
        val dns = "$prefix.1"
        val dnsBytes: ByteArray = parse(dns).let {
            byteArrayOf((it shr 24).toByte(), (it shr 16).toByte(), (it shr 8).toByte(), it.toByte())
        }
        val base: Int get() = parse(network)
    }

    /** La primera es la de siempre; las otras sólo si hay conflicto. */
    val CANDIDATES = listOf("10.255.255", "172.31.255", "198.18.255", "192.0.2").map(::Candidate)

    /** [used]: prefijos IPv4 de las redes reales, como (dirección, longitud del prefijo). */
    fun pick(used: List<Pair<Int, Int>>): Candidate =
        CANDIDATES.firstOrNull { c -> used.none { overlaps(c.base, 24, it.first, it.second) } }
            ?: CANDIDATES.first()

    /** ¿Comparten direcciones los dos prefijos? Una ruta por defecto (/0) no cuenta. */
    fun overlaps(aIp: Int, aLen: Int, bIp: Int, bLen: Int): Boolean {
        if (aLen == 0 || bLen == 0) return false
        val len = minOf(aLen, bLen)
        val mask = if (len >= 32) -1 else (-1 shl (32 - len))
        return (aIp and mask) == (bIp and mask)
    }

    fun toInt(address: ByteArray): Int =
        ((address[0].toInt() and 0xFF) shl 24) or ((address[1].toInt() and 0xFF) shl 16) or
            ((address[2].toInt() and 0xFF) shl 8) or (address[3].toInt() and 0xFF)

    private fun parse(ip: String): Int = toInt(ip.split('.').map { it.toInt().toByte() }.toByteArray())
}
