package com.secretsavior.vpn

import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Reenvía consultas DNS sin bloquear un hilo por consulta. Sin Android: se prueba suelto.
 *
 * Un único socket, protegido una sola vez, y un hilo que recibe. Cada consulta sale con un
 * identificador propio (para que dos apps con el mismo id no se crucen) y se le devuelve
 * el suyo al contestar. Así una página que pide cincuenta nombres a la vez no hace cola.
 *
 * Una respuesta sólo se acepta si cumple las tres: viene de un servidor al que se preguntó por
 * esa consulta, es de la misma pregunta (nombre, tipo y clase) y todavía hay quien la espera. El
 * identificador, de 16 bits, no basta: se pregunta a varios servidores a la vez y las respuestas
 * repetidas llegan tarde, y una de ellas podía coincidir con el id de OTRA consulta en vuelo y
 * entregarse como suya; el cliente la descarta por no ser su pregunta y se queda esperando una
 * respuesta que ya no llega, con segundos de parón.
 *
 * Paquetes por consulta ([ServerStats]): sale a los dos mejores primarios (uno por familia si hay
 * IPv6), y pasado un retraso adaptativo (2,5 × el mejor RTT, 150–800 ms) se pregunta además a los
 * demás, [fallbacks] incluidos. Sin respuesta en [giveUpAfterMs] se contesta null (o con la
 * caducada, si la hay) y el llamador manda SERVFAIL. Si los primarios fallan varias veces seguidas,
 * durante un rato se pregunta a todos desde el principio.
 *
 * Consultas idénticas en vuelo se agrupan: la segunda no sale, espera la misma respuesta y se
 * contesta con su id y las mayúsculas de su pregunta (0x20).
 *
 * Caché ([DnsCache]), primero lo fresco (RFC 8767, modelo del cliente): vigente se contesta al
 * momento (y si está a punto de caducar se renueva); caducada se pregunta a la red y sólo si no hay
 * respuesta en [staleFallbackMs], o la consulta falla, se contesta con la caducada. Servirla de
 * entrada mandaba la primera conexión tras caducar a una IP que quizá ya no servía.
 *
 * Atasco: si [stallQueries] consultas seguidas caducan sin respuesta de nadie ([StallDetector]) se
 * reconstruye el socket (puede estar atascado por estado viejo de NAT/ruta tras un cambio de radio),
 * se olvidan los castigos, se reenvía lo que está en vuelo y se llama a [onStall]. Si persiste tras
 * eso y hay [dot], se pasa unos minutos a DNS sobre TLS, sondeando el UDP de vez en cuando.
 *
 * Si la respuesta llega cortada (TC) se repite la consulta por TCP al mismo servidor.
 *
 * El socket no se conecta a ninguna dirección a propósito: un socket UDP conectado se
 * queda con la ruta del momento y deja de funcionar al pasar de Wi-Fi a datos.
 */
class DnsForwarder(
    private val primaries: List<InetSocketAddress>,
    private val fallbacks: List<InetSocketAddress>,
    private val protect: (DatagramSocket) -> Unit,
    private val protectTcp: (Socket) -> Unit = {},
    /** Retraso fijo antes de preguntar a todos; null = adaptativo según el RTT medido. */
    private val escalateAfterMs: Long? = null,
    private val giveUpAfterMs: Long = 4_000,
    /** null desactiva la caché: cada consulta va a la red. */
    private val cache: DnsCache? = DnsCache(),
    /** Se llama al arrancar cada hilo propio (receptor y TCP); en Android sirve para subirles la prioridad. */
    private val onThreadStart: () -> Unit = {},
    private val staleFallbackMs: Long = STALE_FALLBACK_MS,
    /** Atasco aguas arriba detectado (desde un hilo propio). En Android: pedir que revalide la red. */
    private val onStall: () -> Unit = {},
    stallQueries: Int = StallDetector.STALL_QUERIES,
    stallWindowMs: Long = StallDetector.STALL_WINDOW_MS,
    /** Crea el transporte DNS-sobre-TLS de reserva; recibe a quién entregar los mensajes. null = sin DoT. */
    dot: ((onMessage: (ByteArray, InetSocketAddress) -> Unit) -> DotTransport)? = null,
    private val dotModeMs: Long = DOT_MODE_MS,
    private val dotProbeMs: Long = DOT_PROBE_MS,
    private val warmUpCount: Int = WARM_UP_COUNT,
    /** Reloj en ms para plazos y sondeos; inyectable para que las pruebas no dependan del tiempo real. */
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) : Closeable {

    /** Quien espera una respuesta: cada cliente conserva su id, su pregunta (0x20) y su caducada. */
    private class Waiter(
        val originalId: Int,
        val query: ByteArray,
        /** La caducada que se sirve si la red no contesta a tiempo; ya lleva el id y la pregunta del cliente. */
        val stale: ByteArray?,
        val done: (ByteArray?) -> Unit,
    ) {
        val delivered = AtomicBoolean(false)

        @Volatile
        var staleTimer: ScheduledFuture<*>? = null
    }

    private class Pending(
        /** La consulta con nuestro identificador. */
        val query: ByteArray,
        /** Su pregunta, para comprobar que la respuesta es de esta consulta. */
        val key: String?,
        val startedAt: Long,
    ) {
        @Volatile
        var id = 0

        @Volatile
        var timer: ScheduledFuture<*>? = null

        @Volatile
        var coalesceKey: String? = null

        /** Algún envío no falló: si todos fallan es que no hay red, y eso no es un atasco. */
        @Volatile
        var sendOk = false

        /** A quién se le preguntó y cuándo (la primera vez): sólo de ellos se acepta respuesta. */
        val sentAt = ConcurrentHashMap<InetSocketAddress, Long>()

        private val waiters = ArrayList<Waiter>(1)
        private var finished = false

        @Synchronized
        fun attach(w: Waiter, max: Int): Boolean {
            if (finished || waiters.size >= max) return false
            waiters += w
            return true
        }

        @Synchronized
        fun detach(w: Waiter) {
            waiters.remove(w)
        }

        /** Cierra la consulta y devuelve a quienes la esperaban. */
        @Synchronized
        fun finish(): List<Waiter> {
            finished = true
            return waiters.toList().also { waiters.clear() }
        }
    }

    private val everyone = primaries + fallbacks
    private val stats = ServerStats(everyone)
    private val detector = StallDetector(stallQueries, stallWindowMs)
    private val pending = ConcurrentHashMap<Int, Pending>()

    /** Consultas en vuelo por pregunta idéntica (ver [coalesceKey]). */
    private val inflight = ConcurrentHashMap<String, Pending>()
    private val timers = ScheduledThreadPoolExecutor(1).apply {
        removeOnCancelPolicy = true
        setKeepAliveTime(10, TimeUnit.SECONDS)
        allowCoreThreadTimeOut(true) // sin consultas, sin hilo despierto
    }
    private val tcpPool = ThreadPoolExecutor(
        TCP_THREADS, TCP_THREADS, 10, TimeUnit.SECONDS, LinkedBlockingQueue(TCP_QUEUE),
        { r -> Thread({ onThreadStart(); try { r.run() } catch (t: Throwable) { } }, "savior-dns-tcp").apply { isDaemon = true } },
    ).apply { allowCoreThreadTimeOut(true) }

    @Volatile
    private var socket: DatagramSocket = newSocket()
    private val socketLock = Any()

    @Volatile
    private var closed = false

    @Volatile
    private var lastEscalation = 0L

    @Volatile
    private var escalationStreak = 0

    @Volatile
    private var primariesDownUntil = 0L

    /** Hasta cuándo no se envía a direcciones IPv6 (porque el último envío falló). */
    @Volatile
    private var noIpv6Until = Long.MIN_VALUE

    // Antes que el hilo receptor: él los usa en cuanto arranca.
    private val averageMicros = AtomicLong(0)
    private val answeredCount = AtomicInteger()
    private val failed = AtomicInteger()
    private val staleServed = AtomicInteger()
    private val stalls = AtomicInteger()
    private val recent = BooleanArray(RECENT)
    private var recentPos = 0
    private var recentSeen = 0

    // DNS sobre TLS de reserva.
    private val dotLock = Any()

    @Volatile
    private var dotUntil = DOT_OFF
    private var nextProbeAt = 0L
    private var probesSent = 0
    private val consecutiveStalls = AtomicInteger()
    private val dotTransport: DotTransport? = dot?.invoke { m, from -> accept(m, m.size, from, viaDot = true) }

    // Nada deja morir al receptor: sin él el teléfono entero se queda sin DNS con la VPN «activa». Si
    // el bucle sale por una excepción cualquiera (Throwable) se rehace el socket y se vuelve a empezar.
    private val receiver = Thread({
        onThreadStart()
        var restarts = 0
        while (!closed) {
            try {
                receiveLoop()
                break // salida normal (close)
            } catch (t: Throwable) {
                if (closed) break
                restarts++
                try {
                    Thread.sleep(receiverRestartDelayMs(restarts))
                    rebuildSocket()
                } catch (ie: InterruptedException) {
                    break
                } catch (t2: Throwable) {
                }
            }
        }
    }, "savior-dns").apply {
        isDaemon = true
        start()
    }

    private fun newSocket(): DatagramSocket = DatagramSocket().also {
        // Una página que resuelve decenas de nombres, cada uno enviado a varios servidores, trae
        // ráfagas de respuestas; con el búfer por defecto algunas se pierden y cuestan los 800 ms
        // de la escalada. Si el sistema no deja, se queda con el suyo.
        try {
            it.receiveBufferSize = 1 shl 20
        } catch (e: Exception) {
        }
        protect(it)
    }

    /** Para las pruebas: el socket en uso, por si hay que romperlo. */
    internal fun currentSocket(): DatagramSocket = socket

    /**
     * [done] se llama una sola vez: con la respuesta o con null. Desde otro hilo si va a la red;
     * si sale de la caché, desde el hilo que llama, que así no espera nada.
     */
    fun query(query: ByteArray, done: (ByteArray?) -> Unit) {
        if (closed || query.size < 12) {
            done(null)
            return
        }
        val hit = cache?.lookup(query)
        if (hit != null && !hit.stale) {
            try {
                done(hit.response)
            } catch (e: Exception) {
                // igual que en finish: un fallo al contestar no debe tumbar al llamador
            }
            if (hit.needsRefresh) refresh(query)
            return
        }
        // Caducada o ausente: primero lo fresco. Con caducada, ésta espera como red de seguridad.
        val copy = query.copyOf()
        forward(copy, Waiter(u16(copy, 0), copy, hit?.response, done))
    }

    /**
     * Renueva en segundo plano la pregunta de [query]: una consulta normal cuya respuesta nadie
     * espera; [accept] ya la deja en la caché. Si ya hay una igual en vuelo no se repite.
     */
    private fun refresh(query: ByteArray) = forward(query.copyOf(), null)

    /** [w] null: consulta de fondo (renovación, calentamiento) que nadie espera. */
    private fun forward(query: ByteArray, w: Waiter?) {
        val ck = coalesceKey(query)
        if (ck != null) {
            val existing = inflight[ck]
            if (existing != null) {
                if (w == null) return // ya se está renovando
                if (existing.attach(w, MAX_WAITERS)) {
                    scheduleStale(existing, w)
                    return
                }
                inflight.remove(ck, existing) // terminada o llena: se hace una aparte
            }
        }
        if (pending.size >= MAX_PENDING) {
            if (w != null) complete(w, null)
            return
        }
        val p = Pending(query.copyOf(), DnsPacket.questionKey(query), now())
        var id: Int
        do {
            id = ThreadLocalRandom.current().nextInt(0x10000)
        } while (pending.putIfAbsent(id, p) != null)
        p.id = id
        put16(p.query, 0, id)
        if (w != null) {
            p.attach(w, MAX_WAITERS)
            scheduleStale(p, w)
        }
        if (ck != null && inflight.putIfAbsent(ck, p) == null) p.coalesceKey = ck

        val primariesDown = now() < primariesDownUntil
        dispatch(p, wide = primariesDown)
        val hedge = escalateAfterMs ?: stats.hedgeDelayMs(primaries)
        val direct = primariesDown || hedge >= giveUpAfterMs
        try {
            p.timer = timers.schedule(
                safe { if (direct) expire(id, p) else escalate(id, p, hedge) },
                if (direct) giveUpAfterMs else hedge,
                TimeUnit.MILLISECONDS,
            )
        } catch (e: RejectedExecutionException) {
            // close() se cruzó con esta consulta
            expire(id, p)
        }
    }

    /** Si la red no contesta en [staleFallbackMs], [w] recibe su caducada (la consulta sigue y renueva la caché). */
    private fun scheduleStale(p: Pending, w: Waiter) {
        if (w.stale == null) return
        try {
            w.staleTimer = timers.schedule(safe {
                if (!w.delivered.get()) {
                    p.detach(w)
                    complete(w, null)
                }
            }, staleFallbackMs, TimeUnit.MILLISECONDS)
        } catch (e: RejectedExecutionException) {
            // close(): el llamador ya recibirá null
        }
    }

    /**
     * La clave para agrupar: la consulta entera sin el id y con el nombre en minúsculas. Dos consultas
     * que sólo difieren en el id o en las mayúsculas (0x20) son la misma; si difieren en banderas o
     * en EDNS (tamaño de UDP, DO) no, porque tendrían respuestas distintas.
     */
    private fun coalesceKey(q: ByteArray): String? {
        val end = DnsPacket.parseQuestion(q)?.end ?: return null
        val b = q.copyOf()
        b[0] = 0
        b[1] = 0
        for (i in 12 until end - 4) if (b[i] in 'A'.code.toByte()..'Z'.code.toByte()) b[i] = (b[i] + 32).toByte()
        return String(b, Charsets.ISO_8859_1)
    }

    private fun v6Works() = now() >= noIpv6Until

    /**
     * Saca la consulta por donde toque. [wide]: a todos (reintento, o primarios caídos); si no, a los
     * dos mejores. En modo DoT sale por TLS, y por UDP sólo un sondeo de vez en cuando (o si no se pudo).
     */
    private fun dispatch(p: Pending, wide: Boolean) {
        val down = now() < primariesDownUntil
        val udp = if (wide || down) stats.order(everyone) else stats.initial(primaries, v6Works())
        val dotT = dotTransport
        if (dotT != null && inDotMode()) {
            val now = now()
            for (a in dotT.servers) p.sentAt.putIfAbsent(a, now) // antes de enviar: la respuesta puede llegar al instante
            val ok = dotT.send(p.query)
            if (ok) p.sendOk = true
            if (!ok || wide || shouldProbe()) send(p, udp)
            return
        }
        send(p, udp)
    }

    private fun escalate(id: Int, p: Pending, hedge: Long) {
        if (pending[id] !== p) return
        val t = now()
        escalationStreak = if (t - lastEscalation < STREAK_WINDOW_MS) escalationStreak + 1 else 1
        lastEscalation = t
        if (escalationStreak >= STREAK_TO_MARK_DOWN) primariesDownUntil = t + DOWN_FOR_MS
        for (a in p.sentAt.keys) stats.missed(a) // a quienes se preguntó y no contestaron a tiempo
        dispatch(p, wide = true)
        p.timer = timers.schedule(safe { expire(id, p) }, maxOf(1L, giveUpAfterMs - hedge), TimeUnit.MILLISECONDS)
    }

    private fun expire(id: Int, p: Pending) {
        if (!pending.remove(id, p)) return
        release(p)
        failed.incrementAndGet()
        outcome(false)
        for (a in p.sentAt.keys) stats.missed(a)
        // El atasco se decide ANTES de avisar a los clientes: quien recibe su caducada y lanza otra
        // consulta en el acto (o un test que espera a las N caducadas) debe encontrar el detector ya
        // rearmado; si no, esa consulta nueva saldría «antes» del atasco y no contaría para el siguiente.
        val stalled = detector.expired(p.startedAt, now(), p.sendOk)
        if (stalled) onStalled()
        deliverAll(p, null) // cada uno recibe su caducada, si la tiene, en vez de un SERVFAIL
    }

    private fun release(p: Pending) {
        p.coalesceKey?.let { inflight.remove(it, p) }
    }

    /**
     * Varias consultas seguidas sin que conteste nadie. Se hace lo que un cambio de radio haría pasar
     * por casualidad: socket nuevo (el viejo puede tener NAT/ruta atascados), sin castigos, y se
     * reenvía lo que espera. Después se avisa, para que Android revalide la red. Persistiendo, DoT.
     */
    private fun onStalled() {
        if (closed) return
        val n = consecutiveStalls.incrementAndGet()
        resetPath(newNetwork = false)
        if (dotTransport != null && n >= DOT_AFTER_STALLS) enterDot()
        resendInFlight()
        // El contador se publica al final, con el socket ya nuevo y el modo DoT ya decidido: quien lo
        // lee (estadísticas, pruebas) no puede ver «atasco n» con el estado todavía a medias.
        stalls.incrementAndGet()
        try {
            onStall()
        } catch (t: Throwable) {
            // el aviso no puede tumbar al hilo de los temporizadores
        }
    }

    /** Socket nuevo, castigos fuera y la cuenta de atascos a cero. */
    private fun resetPath(newNetwork: Boolean) {
        rebuildSocket()
        noIpv6Until = Long.MIN_VALUE
        primariesDownUntil = 0
        escalationStreak = 0
        stats.reset(rtt = newNetwork)
        // En un atasco el detector ya se rearmó él mismo en el instante de la detección.
        if (newNetwork) detector.reset(now())
    }

    private fun resendInFlight() {
        for (p in pending.values) dispatch(p, wide = false)
    }

    /**
     * La red por defecto cambió de verdad (Wi-Fi a datos o al revés; no un parpadeo de otra red).
     * Se olvidan las caducadas de la anterior, se hace el reinicio completo del camino (socket nuevo,
     * castigos y RTT fuera, fin del modo DoT), se reenvía lo que está en vuelo y se calientan las
     * consultas más usadas para que las primeras páginas no esperen. Se llama desde el hilo de
     * ConnectivityManager. No toca los temporizadores: la escalada y el abandono siguen su curso, y
     * reenviar es inofensivo (la primera respuesta gana).
     */
    fun onNetworkChanged() {
        if (closed) return
        cache?.forgetStale()
        synchronized(dotLock) { if (dotUntil != DOT_OFF) exitDot() }
        consecutiveStalls.set(0)
        resetPath(newNetwork = true)
        resendInFlight()
        warmUp()
    }

    /** Renueva por la red nueva las consultas más servidas; pasan por el reenviador de siempre. */
    private fun warmUp() {
        val c = cache ?: return
        if (warmUpCount <= 0 || pending.size > MAX_PENDING / 2) return
        for (q in c.hottest(warmUpCount)) forward(q, null)
    }

    /** Tiempo medio de respuesta (media móvil), para verlo en la app y saber si el resolutor va lento. */
    val averageMs: Long get() = averageMicros.get() / 1000

    /** Para la interfaz: cuántas consultas se contestaron desde la caché y cuántas pasaron por ella. */
    val cacheHits: Int get() = cache?.let { it.hits + staleServed.get() } ?: 0
    val cacheLookups: Int get() = cache?.let { it.hits + it.staleHits + it.misses } ?: 0

    /** Consultas contestadas y consultas que se quedaron sin respuesta, desde que arrancó. */
    val answered: Int get() = answeredCount.get()
    val unanswered: Int get() = failed.get()

    /** Veces que se detectó un atasco aguas arriba y se recuperó el camino. */
    val stallRecoveries: Int get() = stalls.get()

    /** ¿Se está usando DNS sobre TLS porque el UDP no pasa? */
    val usingDot: Boolean get() = dotTransport != null && inDotMode()

    /** De las últimas [RECENT] consultas, cuántas se quedaron sin respuesta y cuántas hubo. */
    val recentFailed: Int get() = synchronized(recent) { (0 until minOf(recentSeen, RECENT)).count { !recent[it] } }
    val recentTotal: Int get() = synchronized(recent) { minOf(recentSeen, RECENT) }

    private fun outcome(ok: Boolean) = synchronized(recent) {
        recent[recentPos] = ok
        recentPos = (recentPos + 1) % RECENT
        recentSeen++
    }

    private fun noteLatency(ms: Long) {
        val sample = ms * 1000
        val n = answeredCount.incrementAndGet()
        // Las primeras se promedian sin más; luego pesa más lo reciente (1/32).
        averageMicros.updateAndGet { avg -> if (n <= 32) avg + (sample - avg) / n else avg + (sample - avg) / 32 }
        outcome(true)
    }

    // --- DNS sobre TLS ---------------------------------------------------------------------

    private fun inDotMode(): Boolean {
        val until = dotUntil
        if (until == DOT_OFF) return false
        val t = now()
        if (t < until) return true
        synchronized(dotLock) {
            if (dotUntil == DOT_OFF) return false
            if (probesSent > 0) { // los sondeos de UDP siguen sin contestar: el bloqueo sigue
                dotUntil = t + dotModeMs
                probesSent = 0
                return true
            }
            exitDot()
            return false
        }
    }

    private fun enterDot() {
        synchronized(dotLock) {
            if (dotUntil != DOT_OFF) return
            dotUntil = now() + dotModeMs
            nextProbeAt = now() + dotProbeMs
            probesSent = 0
        }
    }

    private fun exitDot() {
        synchronized(dotLock) {
            dotUntil = DOT_OFF
            probesSent = 0
            consecutiveStalls.set(0)
            try {
                dotTransport?.disconnect()
            } catch (e: Exception) {
            }
        }
    }

    private fun shouldProbe(): Boolean {
        synchronized(dotLock) {
            val t = now()
            if (t < nextProbeAt) return false
            nextProbeAt = t + dotProbeMs
            probesSent++
            return true
        }
    }

    // --- UDP -------------------------------------------------------------------------------

    private fun send(p: Pending, to: List<InetSocketAddress>) {
        // Sin IPv6 cada envío a un servidor IPv6 lanza una excepción, y crearlas no sale gratis en
        // el camino caliente: tras un fallo se dejan de usar un minuto. Si no hubiera otra cosa a
        // la que enviar se envía igualmente: nunca se deja una consulta sin destino.
        val skipV6 = !v6Works() && to.any { it.address !is Inet6Address }
        for (addr in to) {
            val v6 = addr.address is Inet6Address
            if (skipV6 && v6) continue
            p.sentAt.putIfAbsent(addr, now()) // antes de enviar: la respuesta puede llegar al instante
            try {
                socket.send(DatagramPacket(p.query, p.query.size, addr))
                p.sendOk = true
            } catch (e: Exception) {
                if (v6) noIpv6Until = now() + IPV6_BACKOFF_MS
                // Sin red en este instante (IOException) o sin IPv6 en este sistema
                // (UnsupportedAddressTypeException, que no es de E/S): el temporizador decidirá.
                // Dejarla escapar tumbaría al hilo que llama, que puede ser el lector del túnel.
            }
        }
    }

    private fun receiveLoop() {
        val buf = ByteArray(MAX_RESPONSE)
        val packet = DatagramPacket(buf, buf.size)
        var errors = 0
        while (!closed) {
            val s = socket
            try {
                packet.length = buf.size
                s.receive(packet)
                errors = 0
            } catch (e: IOException) {
                if (closed) break
                // Lo cerró a propósito [rebuildSocket] (atasco o cambio de red): a leer del nuevo, sin esperas.
                if (s !== socket) continue
                // El socket puede estar roto (lo cerró el sistema, cambió la red). Sin esperar,
                // este bucle giraría a toda velocidad con un núcleo al 100 %; tras varios fallos
                // seguidos se crea un socket nuevo.
                errors++
                try {
                    Thread.sleep(minOf(MAX_BACKOFF_MS, 20L shl minOf(errors, 6)))
                } catch (ie: InterruptedException) {
                    break
                }
                if (errors >= REBUILD_AFTER || socket.isClosed) { // uno cerrado no se recupera solo
                    rebuildSocket()
                    errors = 0
                }
                continue
            }
            try {
                val from = packet.socketAddress as? InetSocketAddress ?: continue
                accept(buf, packet.length, from, viaDot = false)
            } catch (e: Throwable) {
                // un paquete que falla no tumba al receptor: el DNS de todo el teléfono depende de él
            }
        }
    }

    private fun rebuildSocket() {
        synchronized(socketLock) {
            if (closed) return
            try {
                val old = socket
                socket = newSocket()
                old.close()
            } catch (e: Throwable) {
                // se reintenta en la siguiente vuelta
            }
        }
    }

    private fun accept(buf: ByteArray, len: Int, from: InetSocketAddress, viaDot: Boolean) {
        if (len < 12 || !DnsPacket.isResponse(buf, len)) return
        val id = u16(buf, 0)
        val p = pending[id] ?: return // tardía o repetida
        // Todas estas comprobaciones van ANTES de quitarla de la lista: una respuesta que no es
        // la buena no debe gastar la consulta, o la buena llegaría después a nadie.
        val sent = p.sentAt[from] ?: return
        if (p.key != null && DnsPacket.questionKey(buf, len) != p.key) return
        if (!pending.remove(id, p)) return

        p.timer?.cancel(false)
        release(p)
        val t = now()
        noteLatency(t - p.startedAt)
        stats.answered(from, t - sent)
        detector.answered()
        consecutiveStalls.set(0)
        // Contestó el UDP: ya no hace falta el túnel TLS.
        if (!viaDot && dotUntil != DOT_OFF) synchronized(dotLock) { if (dotUntil != DOT_OFF) exitDot() }
        val response = buf.copyOf(len)
        cache?.store(p.query, response) // antes de contestar: la siguiente consulta ya la encuentra
        if (!viaDot && DnsPacket.isTruncated(response)) tcpFallback(p, from, response) else deliverAll(p, response)
    }

    /** La respuesta llegó cortada: se repite por TCP a quien contestó, y si no se puede, se entrega cortada. */
    private fun tcpFallback(p: Pending, server: InetSocketAddress, truncated: ByteArray) {
        // Lo que el cliente acepta por UDP; un poco más de 512 B suele caber en su búfer.
        val limit = maxOf(DnsPacket.ednsSize(p.query), 1232).coerceAtMost(4096)
        try {
            tcpPool.execute {
                try {
                    val full = queryTcp(server, p.query)
                    val usable = full != null && full.size <= limit && !DnsPacket.isTruncated(full) &&
                        u16(full, 0) == u16(p.query, 0) && DnsPacket.questionKey(full) == p.key
                    if (usable) {
                        cache?.store(p.query, full!!)
                        deliverAll(p, full!!)
                    } else {
                        deliverAll(p, truncated)
                    }
                } catch (t: Throwable) {
                    deliverAll(p, truncated) // una sola vez: deliverAll ya vació a los que esperaban
                }
            }
        } catch (e: RejectedExecutionException) {
            deliverAll(p, truncated)
        }
    }

    private fun queryTcp(server: InetSocketAddress, query: ByteArray): ByteArray? = try {
        Socket().use { s ->
            s.bind(null) // reserva el descriptor: sin él no se puede proteger
            protectTcp(s)
            s.soTimeout = TCP_READ_MS
            s.connect(server, TCP_CONNECT_MS)
            val out = s.getOutputStream()
            out.write(byteArrayOf((query.size shr 8).toByte(), query.size.toByte()))
            out.write(query)
            out.flush()
            val input = DataInputStream(s.getInputStream())
            val n = input.readUnsignedShort()
            if (n < 12) null else ByteArray(n).also { input.readFully(it) }
        }
    } catch (e: Exception) {
        null
    }

    // --- Entrega ---------------------------------------------------------------------------

    /** [response] llegó (o null: la consulta se rindió): a cada uno de los que esperaban. */
    private fun deliverAll(p: Pending, response: ByteArray?) {
        for (w in p.finish()) complete(w, response)
    }

    /**
     * Entrega a [w] una sola vez. Con respuesta: con su id y las mayúsculas de su pregunta. Sin ella, o
     * con un SERVFAIL del servidor, su caducada si la tiene (nunca una negativa: la caché no las guarda así).
     */
    private fun complete(w: Waiter, response: ByteArray?) {
        if (!w.delivered.compareAndSet(false, true)) return
        w.staleTimer?.cancel(false)
        val out: ByteArray? = when {
            w.stale != null && (response == null || (response[3].toInt() and 0xF) == RCODE_SERVFAIL) -> {
                staleServed.incrementAndGet()
                w.stale
            }
            response == null -> null
            else -> personalize(response, w)
        }
        try {
            w.done(out)
        } catch (e: Exception) {
            // un fallo al contestar una consulta no debe tumbar las demás
        }
    }

    private fun personalize(response: ByteArray, w: Waiter): ByteArray {
        val out = response.copyOf()
        put16(out, 0, w.originalId)
        val end = DnsPacket.parseQuestion(w.query)?.end ?: return out
        if (end <= out.size) System.arraycopy(w.query, 12, out, 12, end - 12)
        return out
    }

    override fun close() {
        closed = true
        socket.close()
        timers.shutdownNow()
        tcpPool.shutdownNow()
        try {
            dotTransport?.close()
        } catch (e: Exception) {
        }
        pending.clear()
        inflight.clear()
        receiver.interrupt()
    }

    private fun now() = clock()

    /** Una tarea de temporizador que falla cancelaría sólo su ejecución; así ni siquiera deja traza fatal. */
    private fun safe(block: () -> Unit) = Runnable {
        try {
            block()
        } catch (t: Throwable) {
            // el hilo de los temporizadores sirve a todas las consultas
        }
    }

    companion object {
        /** Espera antes de reanudar el receptor tras un fallo inesperado: 50 ms, duplicando hasta 2 s. */
        fun receiverRestartDelayMs(restarts: Int): Long = (50L shl (restarts - 1).coerceIn(0, 6)).coerceAtMost(2_000L)

        /** RFC 8767: cuánto se espera a la red antes de contestar con la caducada. */
        const val STALE_FALLBACK_MS = 500L

        /** Cuántas consultas iguales pueden colgar de una sola en vuelo. */
        const val MAX_WAITERS = 64

        /** Las entradas más usadas que se renuevan tras un cambio de red. */
        const val WARM_UP_COUNT = 20

        /** Atascos seguidos (sin respuesta de nadie entre medias) tras los cuales se pasa a DoT. */
        const val DOT_AFTER_STALLS = 2
        const val DOT_MODE_MS = 5 * 60_000L
        const val DOT_PROBE_MS = 30_000L

        private const val DOT_OFF = Long.MIN_VALUE
        private const val MAX_PENDING = 2048
        private const val MAX_RESPONSE = 65_535 // el máximo de UDP: una respuesta grande no se corta
        private const val STREAK_WINDOW_MS = 10_000L
        private const val STREAK_TO_MARK_DOWN = 3
        private const val DOWN_FOR_MS = 30_000L
        private const val RECENT = 50
        private const val REBUILD_AFTER = 5
        private const val MAX_BACKOFF_MS = 1_000L
        private const val IPV6_BACKOFF_MS = 60_000L
        private const val TCP_THREADS = 4
        private const val TCP_QUEUE = 32
        private const val TCP_CONNECT_MS = 2_000
        private const val TCP_READ_MS = 3_000
        private const val RCODE_SERVFAIL = 2

        private fun u16(b: ByteArray, o: Int) = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

        private fun put16(b: ByteArray, o: Int, v: Int) {
            b[o] = (v shr 8).toByte()
            b[o + 1] = v.toByte()
        }
    }
}
