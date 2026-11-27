package com.secretsavior.vpn

import java.net.InetAddress
import java.util.Arrays

/**
 * Resolutores públicos de DNS (clásico, DoH, DoT, DoQ) por dirección IP. El filtro por nombre
 * ([DnsFilter]) no sirve contra un navegador con «DNS seguro personalizado» apuntando a
 * `https://1.1.1.1/dns-query`: no hay nombre que bloquear. Estas direcciones se enrutan al túnel
 * y allí se filtran (UDP/TCP 53) o se rechazan al instante (el resto), para que la app vuelva al
 * DNS del sistema. Sin Android.
 *
 * Quedan fuera, a propósito, los propios resolutores aguas arriba (CleanBrowsing Adult, Cloudflare
 * for Families): el reenviador los alcanza con sockets protegidos y no deben pasar por el túnel.
 * Sólo van los perfiles de CleanBrowsing SIN filtro de adultos.
 *
 * Una entrada es una dirección o un prefijo ("45.90.28.0/24", "2a07:a8c0::/32"); en IPv6 los
 * prefijos deben ser de /64 o menos. Cada entrada de más es una ruta más en la VPN: sólo lo que
 * de verdad es un servicio de DNS. Los prefijos de NextDNS/Control D son de anycast propio.
 */
object Resolvers {

    private val ENTRIES = listOf(
        // Google
        "8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844",
        "2001:4860:4860::64", "2001:4860:4860::6464",
        // Cloudflare (sin 1.1.1.3 / 1.0.0.3: es nuestra reserva)
        "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "162.159.36.1", "162.159.46.1",
        "2606:4700:4700::1111", "2606:4700:4700::1001", "2606:4700:4700::1112", "2606:4700:4700::1002",
        // Quad9
        "9.9.9.9", "149.112.112.112", "9.9.9.10", "149.112.112.10", "9.9.9.11", "149.112.112.11",
        "9.9.9.12", "149.112.112.12",
        "2620:fe::fe", "2620:fe::9", "2620:fe::10", "2620:fe::fe:10", "2620:fe::11", "2620:fe::fe:11",
        "2620:fe::12", "2620:fe::fe:12",
        // OpenDNS (Cisco)
        "208.67.222.222", "208.67.220.220", "208.67.222.123", "208.67.220.123",
        "2620:119:35::35", "2620:119:53::53",
        // AdGuard
        "94.140.14.14", "94.140.15.15", "94.140.14.15", "94.140.15.16", "94.140.14.140", "94.140.14.141",
        "176.103.130.130", "176.103.130.131",
        "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff", "2a10:50c0::1:ff", "2a10:50c0::2:ff",
        "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff",
        // NextDNS (anycast propio)
        "45.90.28.0/24", "45.90.30.0/24", "2a07:a8c0::/32", "2a07:a8c1::/32",
        // Control D
        "76.76.2.0/24", "76.76.10.0/24", "2606:1a40::", "2606:1a40::1", "2606:1a40::2", "2606:1a40::3",
        "2606:1a40:1::", "2606:1a40:1::1",
        // Mullvad
        "194.242.2.2", "194.242.2.3", "194.242.2.4", "194.242.2.5", "194.242.2.6", "194.242.2.9",
        "2a07:e340::2", "2a07:e340::3", "2a07:e340::4", "2a07:e340::5", "2a07:e340::6", "2a07:e340::9",
        // dns.sb
        "185.222.222.222", "45.11.45.11", "2a09::", "2a11::",
        // DNS0.eu
        "193.110.81.0", "185.253.5.0", "193.110.81.1", "185.253.5.1", "2a0f:fc80::", "2a0f:fc81::",
        // CIRA Canadian Shield
        "149.112.121.10", "149.112.122.10", "149.112.121.20", "149.112.122.20",
        "149.112.121.30", "149.112.122.30",
        "2620:10a:80bb::10", "2620:10a:80bc::10", "2620:10a:80bb::20", "2620:10a:80bc::20",
        // Comodo
        "8.26.56.26", "8.20.247.20",
        // Yandex
        "77.88.8.8", "77.88.8.1", "77.88.8.88", "77.88.8.2", "77.88.8.7", "77.88.8.3",
        "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff", "2a02:6b8::feed:bad", "2a02:6b8:0:1::feed:bad",
        // AliDNS
        "223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1",
        // DNSPod / doh.pub (Tencent)
        "119.29.29.29", "119.28.28.28", "182.254.116.116", "182.254.118.118", "2402:4e00::",
        // 360
        "101.226.4.6", "218.30.118.6", "123.125.81.6", "140.207.198.6",
        // CleanBrowsing SIN filtro de adultos (Security); el de adultos es el nuestro
        "185.228.168.9", "185.228.169.9", "2a0d:2a00:1::2", "2a0d:2a00:2::2",
        // Level3 / Verisign / Neustar y otros públicos clásicos
        "4.2.2.1", "4.2.2.2", "4.2.2.3", "4.2.2.4", "4.2.2.5", "4.2.2.6", "209.244.0.3", "209.244.0.4",
        "64.6.64.6", "64.6.65.6", "2620:74:1b::1:1", "2620:74:1c::2:2",
        "156.154.70.1", "156.154.71.1", "74.82.42.42", "80.80.80.80", "80.80.81.81",
        "84.200.69.80", "84.200.70.40", "101.101.101.101", "101.102.103.104", "116.202.176.26",
        "76.76.19.19", "76.223.122.150",
    )

    /** Una ruta para la VPN: dirección y longitud del prefijo (32/128 para un host). */
    class Route(val address: ByteArray, val prefix: Int) {
        val v6: Boolean get() = address.size == 16
        val inet: InetAddress get() = InetAddress.getByAddress(address)
    }

    /**
     * Estructura de consulta sin cajas: el lector del túnel la usa por cada paquete. Hosts en
     * vectores ordenados (búsqueda binaria) y prefijos en vectores paralelos, que son pocos.
     */
    class Table internal constructor(
        private val hosts4: IntArray,
        private val pfx4: IntArray,
        private val mask4: IntArray,
        private val hosts6Hi: LongArray,
        private val hosts6Lo: LongArray,
        private val pfx6: LongArray,
        private val mask6: LongArray,
        val routes: List<Route>,
    ) {
        fun containsV4(ip: Int): Boolean {
            if (Arrays.binarySearch(hosts4, ip) >= 0) return true
            for (i in pfx4.indices) if (ip and mask4[i] == pfx4[i]) return true
            return false
        }

        /** [hi] y [lo]: las dos mitades de la dirección de 128 bits. */
        fun containsV6(hi: Long, lo: Long): Boolean {
            var a = 0
            var b = hosts6Hi.size - 1
            while (a <= b) {
                val m = (a + b) ushr 1
                var c = java.lang.Long.compare(hosts6Hi[m], hi)
                if (c == 0) c = java.lang.Long.compare(hosts6Lo[m], lo)
                if (c == 0) return true
                if (c < 0) a = m + 1 else b = m - 1
            }
            for (i in pfx6.indices) if (hi and mask6[i] == pfx6[i]) return true
            return false
        }

        fun contains(address: InetAddress): Boolean {
            val b = address.address
            return if (b.size == 4) containsV4(int(b)) else containsV6(long(b, 0), long(b, 8))
        }
    }

    /** [excluded]: direcciones que jamás deben capturarse (los resolutores aguas arriba). */
    fun build(excluded: Collection<InetAddress> = emptyList()): Table {
        val skip = excluded.map { it.address.toList() }.toSet()
        val h4 = ArrayList<Int>()
        val h6 = ArrayList<Pair<Long, Long>>()
        val p4 = ArrayList<Pair<Int, Int>>() // base, longitud
        val p6 = ArrayList<Pair<Long, Int>>()
        for (e in ENTRIES) {
            val slash = e.indexOf('/')
            val addr = parse(if (slash < 0) e else e.substring(0, slash))
            val b = addr.address
            if (slash < 0) {
                if (b.toList() in skip) continue
                if (b.size == 4) h4 += int(b) else h6 += long(b, 0) to long(b, 8)
            } else {
                val len = e.substring(slash + 1).toInt()
                // un prefijo que cubriría un resolutor nuestro se descarta entero
                if (excluded.any { covers(b, len, it.address) }) continue
                if (b.size == 4) {
                    require(len in 8..31)
                    p4 += (int(b) and mask4(len)) to len
                } else {
                    require(len in 16..64)
                    p6 += (long(b, 0) and mask6(len)) to len
                }
            }
        }
        val hosts4 = h4.distinct().sorted().toIntArray()
        val hosts6 = h6.distinct().sortedWith { x, y ->
            val c = java.lang.Long.compare(x.first, y.first)
            if (c != 0) c else java.lang.Long.compare(x.second, y.second)
        }
        val routes = ArrayList<Route>()
        for (x in hosts4) routes += Route(bytes4(x), 32)
        for (x in p4.distinct()) routes += Route(bytes4(x.first), x.second)
        for (x in hosts6) routes += Route(bytes6(x.first, x.second), 128)
        for (x in p6.distinct()) routes += Route(bytes6(x.first, 0), x.second)
        return Table(
            hosts4,
            p4.distinct().map { it.first }.toIntArray(), p4.distinct().map { mask4(it.second) }.toIntArray(),
            hosts6.map { it.first }.toLongArray(), hosts6.map { it.second }.toLongArray(),
            p6.distinct().map { it.first }.toLongArray(), p6.distinct().map { mask6(it.second) }.toLongArray(),
            routes,
        )
    }

    /** Las entradas tal cual, para las pruebas. */
    internal fun entries(): List<String> = ENTRIES

    internal fun parse(literal: String): InetAddress {
        require(literal.isNotEmpty() && literal.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == '.' || it == ':' }) {
            "no es una dirección: $literal"
        }
        val a = InetAddress.getByName(literal) // sólo literales: no hay consulta de red
        require(a.address.size == (if (':' in literal) 16 else 4)) { "familia inesperada: $literal" }
        return a
    }

    private fun covers(prefix: ByteArray, len: Int, addr: ByteArray): Boolean {
        if (prefix.size != addr.size) return false
        return if (prefix.size == 4) int(prefix) and mask4(len) == int(addr) and mask4(len)
        else long(prefix, 0) and mask6(len) == long(addr, 0) and mask6(len)
    }

    private fun mask4(len: Int): Int = if (len == 0) 0 else -1 shl (32 - len)
    private fun mask6(len: Int): Long = if (len == 0) 0 else -1L shl (64 - len)

    internal fun int(b: ByteArray): Int =
        ((b[0].toInt() and 0xFF) shl 24) or ((b[1].toInt() and 0xFF) shl 16) or
            ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF)

    internal fun long(b: ByteArray, o: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[o + i].toLong() and 0xFF)
        return v
    }

    private fun bytes4(v: Int) = byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte())

    private fun bytes6(hi: Long, lo: Long) = ByteArray(16) { i ->
        (if (i < 8) hi shr (56 - 8 * i) else lo shr (56 - 8 * (i - 8))).toByte()
    }
}
