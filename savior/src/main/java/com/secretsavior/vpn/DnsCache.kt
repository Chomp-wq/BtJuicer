package com.secretsavior.vpn

/**
 * Caché de respuestas DNS con "serve-stale" y prefetch. Sin Android: se prueba suelto.
 *
 * Por qué: toda consulta que no está en la caché del propio Android paga una ida y vuelta
 * entera hasta CleanBrowsing (40–150 ms, más con datos móviles). Las CDN usan TTL cortos
 * (20–60 s), así que los mismos nombres se vuelven a pedir sin parar y casi cada conexión
 * espera ese viaje. Servir al momento una respuesta algo caducada y renovarla en segundo
 * plano (RFC 8767 "serve-stale"; Unbound lo llama serve-expired y AdGuard "optimistic cache")
 * saca esa espera del camino crítico de casi todas las conexiones.
 *
 * - Sólo se guardan consultas estándar (opcode 0, una pregunta) y respuestas completas: sin
 *   truncar y con RCODE 0 (sin error) o 3 (NXDOMAIN). Una SERVFAIL o una respuesta cortada
 *   nunca se reutiliza.
 * - El TTL de una respuesta con datos es el menor de su sección de respuestas (máx. 24 h; con
 *   TTL 0 no se guarda). El de una negativa (NXDOMAIN o NODATA) sale del SOA de la sección de
 *   autoridad, entre 5 s y 5 min (30 s si no trae). Las negativas jamás se sirven caducadas:
 *   un "no existe" viejo es peor que esperar.
 * - Al servir se le pone el identificador y la pregunta del cliente (puede venir con otras
 *   mayúsculas, 0x20) y se descuenta de cada TTL lo que lleva guardada, para que el cliente no
 *   la cachee más tiempo del debido. Una respuesta caducada lleva [staleTtlSec] en todos sus
 *   TTL: lo justo para que la app reintente pronto y ya encuentre la renovada.
 * - El pseudo-registro OPT (tipo 41) lleva en su "TTL" las banderas y la versión de EDNS: nunca
 *   se toca.
 *
 * Los contadores sirven para enseñar en la app qué parte de las consultas se contesta desde aquí.
 * Es seguro entre hilos: el reenviador la usa desde el lector del túnel, el receptor y los
 * temporizadores.
 */
class DnsCache(
    private val maxEntries: Int = 2048,
    private val maxStaleMs: Long = 3 * 60 * 60 * 1000L,
    private val staleTtlSec: Int = 10,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) {

    /**
     * Lo que devuelve [lookup]. [stale]: estaba caducada. [needsRefresh]: conviene renovarla ya
     * (caducada, o a punto de caducar), y quien llama decide cómo.
     */
    class Hit(val response: ByteArray, val stale: Boolean, val needsRefresh: Boolean)

    private class Entry(
        val response: ByteArray,
        val storedAt: Long,
        val ttlSec: Int,
        val negative: Boolean,
        /** Dónde está cada campo TTL (4 bytes) que se reescribe; el OPT no está. */
        val ttlOffsets: IntArray,
        /** Fin de la pregunta dentro de [response]. */
        val questionEnd: Int,
        /** La consulta que la originó, para poder renovarla tras un cambio de red (ver [hottest]). */
        val query: ByteArray,
        /** Veces que se sirvió: lo popular se renueva primero. Se conserva al renovar la entrada. */
        var hits: Int = 0,
    )

    private val lock = Any()
    private val map = object : LinkedHashMap<String, Entry>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?) = size > maxEntries
    }
    private var hitCount = 0
    private var staleCount = 0
    private var missCount = 0

    /** Las entradas guardadas antes de este instante no se sirven caducadas (ver [forgetStale]). */
    private var staleCutoff = Long.MIN_VALUE

    /** Contestadas con una respuesta vigente, contestadas con una caducada, y sin respuesta. */
    val hits: Int get() = synchronized(lock) { hitCount }
    val staleHits: Int get() = synchronized(lock) { staleCount }
    val misses: Int get() = synchronized(lock) { missCount }

    /**
     * Deja de servir caducadas las respuestas guardadas hasta ahora; vigentes (dentro de su TTL)
     * siguen valiendo. Se llama al cambiar de red: lo que contestó otra red (un Wi-Fi de hotel o
     * de portal cautivo que secuestra el DNS, por ejemplo) no debe reutilizarse durante horas al
     * salir de ella. Dentro de su TTL sí es aceptable, y es lo que hace también la caché de
     * Android. Lo guardado después de esta llamada se sirve caducado con normalidad.
     */
    fun forgetStale() {
        val t = clock()
        synchronized(lock) { staleCutoff = t }
    }

    /**
     * Las consultas de las [n] entradas más servidas (con datos, no negativas), de más a menos. Tras
     * cambiar de red se renuevan: los nombres que se usan sin parar ya estarán resueltos para la red
     * nueva cuando la primera página los pida. Copias: quien llama puede tocarlas.
     */
    fun hottest(n: Int): List<ByteArray> = synchronized(lock) {
        map.values.filter { it.hits > 0 && !it.negative }.sortedByDescending { it.hits }.take(n).map { it.query.copyOf() }
    }

    /** Entradas guardadas ahora mismo. */
    val size: Int get() = synchronized(lock) { map.size }

    /** La respuesta para [query], o null si no hay una que valga. Nunca lanza. */
    fun lookup(query: ByteArray): Hit? {
        val hit = try {
            find(query)
        } catch (e: Exception) {
            null // un paquete raro es un fallo de caché, no un error
        }
        synchronized(lock) {
            when {
                hit == null -> missCount++
                hit.stale -> staleCount++
                else -> hitCount++
            }
        }
        return hit
    }

    private fun find(query: ByteArray): Hit? {
        val key = standardKey(query) ?: return null
        val q = DnsPacket.parseQuestion(query) ?: return null
        val now = clock()
        synchronized(lock) {
            val e = map[key] ?: return null
            if (e.questionEnd != q.end) return null // mismo nombre sin importar mayúsculas = mismo largo
            if (e.response.size > DnsPacket.ednsSize(query)) return null // no le cabría por UDP
            if (e.hits < Int.MAX_VALUE) e.hits++
            val ttlMs = e.ttlSec * 1000L
            val age = now - e.storedAt
            val out = e.response.copyOf()
            System.arraycopy(query, 0, out, 0, 2)
            System.arraycopy(query, 12, out, 12, q.end - 12)
            if (age < ttlMs) {
                val elapsed = (maxOf(age, 0L) / 1000).toInt()
                for (o in e.ttlOffsets) {
                    val ttl = u32(out, o)
                    put32(out, o, maxOf(1L, ttl - elapsed))
                }
                val remaining = ttlMs - age
                val refresh = !e.negative && remaining < maxOf(ttlMs / 10, PREFETCH_MIN_MS)
                return Hit(out, stale = false, needsRefresh = refresh)
            }
            if (!e.negative && age - ttlMs < maxStaleMs && e.storedAt >= staleCutoff) {
                for (o in e.ttlOffsets) put32(out, o, staleTtlSec.toLong())
                return Hit(out, stale = true, needsRefresh = true)
            }
            map.remove(key) // ya no sirve ni caducada
            return null
        }
    }

    /** Guarda [response] como contestación a [query] si es de las que se pueden reutilizar. Nunca lanza. */
    fun store(query: ByteArray, response: ByteArray) {
        try {
            val key = standardKey(query) ?: return
            val entry = parse(key, response, query) ?: return
            synchronized(lock) {
                // La popularidad sobrevive a la renovación: si no, lo prefetcheado volvería a empezar de cero.
                map[key]?.let { entry.hits = it.hits }
                map[key] = entry
            }
        } catch (e: Exception) {
            // una respuesta que no se entiende simplemente no se guarda
        }
    }

    /** La clave de una consulta estándar (opcode 0, una pregunta), o null si no es cacheable. */
    private fun standardKey(query: ByteArray): String? {
        if (query.size < 17) return null
        val flags = u16(query, 2)
        if (flags and 0x8000 != 0) return null // una respuesta
        if ((flags shr 11) and 0xF != 0) return null // opcode distinto de QUERY
        if (u16(query, 4) != 1) return null
        return DnsPacket.questionKey(query)
    }

    private fun parse(key: String, r: ByteArray, query: ByteArray): Entry? {
        val len = r.size
        if (len < 17) return null
        val flags = u16(r, 2)
        if (flags and 0x8000 == 0) return null // no es una respuesta
        if (flags and 0x0200 != 0) return null // cortada (TC)
        val rcode = flags and 0xF
        if (rcode != 0 && rcode != 3) return null
        if ((flags shr 11) and 0xF != 0 || u16(r, 4) != 1) return null
        if (DnsPacket.questionKey(r) != key) return null

        var pos = DnsPacket.skipName(r, 12)
        if (pos < 0 || pos + 4 > len) return null
        pos += 4
        val questionEnd = pos

        val an = u16(r, 6)
        val ns = u16(r, 8)
        val ar = u16(r, 10)
        val offsets = ArrayList<Int>()
        var minAnswer = Long.MAX_VALUE
        var soaTtl = -1L

        for (i in 0 until an + ns + ar) {
            pos = DnsPacket.skipName(r, pos)
            if (pos < 0 || pos + 10 > len) return null
            val type = u16(r, pos)
            val ttl = u32(r, pos + 4)
            val rdlen = u16(r, pos + 8)
            val rdata = pos + 10
            if (rdata + rdlen > len) return null
            if (type != TYPE_OPT) offsets += pos + 4
            if (i < an) {
                minAnswer = minOf(minAnswer, ttl)
            } else if (i < an + ns && type == TYPE_SOA && soaTtl < 0) {
                // El SOA manda en las negativas: el menor entre su TTL y su campo MINIMUM (RFC 2308).
                var m = DnsPacket.skipName(r, rdata)
                if (m >= 0) m = DnsPacket.skipName(r, m)
                soaTtl = if (m >= 0 && m + 20 <= rdata + rdlen) minOf(ttl, u32(r, m + 16)) else ttl
            }
            pos = rdata + rdlen
        }

        val negative = rcode == 3 || an == 0
        val ttl: Long = if (negative) {
            if (soaTtl >= 0) soaTtl.coerceIn(NEG_MIN_SEC, NEG_MAX_SEC) else NEG_DEFAULT_SEC
        } else {
            minAnswer.coerceAtMost(MAX_TTL_SEC)
        }
        if (ttl <= 0) return null
        return Entry(r.copyOf(), clock(), ttl.toInt(), negative, offsets.toIntArray(), questionEnd, query.copyOf())
    }

    private companion object {
        const val TYPE_SOA = 6
        const val TYPE_OPT = 41
        const val MAX_TTL_SEC = 86_400L
        const val NEG_MIN_SEC = 5L
        const val NEG_MAX_SEC = 300L
        const val NEG_DEFAULT_SEC = 30L

        /** Con menos de esto de vida (o el 10 % del TTL, lo que sea más) se renueva antes de caducar. */
        const val PREFETCH_MIN_MS = 3_000L

        fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

        /** Un TTL son 32 bits; si trae el bit alto puesto se trata como 0 (RFC 2181 §8). */
        fun u32(b: ByteArray, o: Int): Long {
            val v = (u16(b, o).toLong() shl 16) or u16(b, o + 2).toLong()
            return if (v > Int.MAX_VALUE) 0 else v
        }

        fun put32(b: ByteArray, o: Int, v: Long) {
            b[o] = (v shr 24).toByte()
            b[o + 1] = (v shr 16).toByte()
            b[o + 2] = (v shr 8).toByte()
            b[o + 3] = v.toByte()
        }
    }
}
