package com.secretsavior

import com.secretsavior.vpn.DefaultNetworkTracker
import com.secretsavior.vpn.DefaultNetworkTracker.Caps
import com.secretsavior.vpn.DefaultNetworkTracker.Transport
import com.secretsavior.vpn.MinGap
import com.secretsavior.vpn.ServerStats
import com.secretsavior.vpn.StallDetector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress

class StatsAndTrackerTest {

    private val v4a = InetSocketAddress("185.228.168.10", 53)
    private val v4b = InetSocketAddress("185.228.169.11", 53)
    private val v6a = InetSocketAddress("2a0d:2a00:1::1", 53)
    private val v6b = InetSocketAddress("2a0d:2a00:2::1", 53)
    private val all = listOf(v4a, v4b, v6a, v6b)

    private var clock = 1_000_000L
    private fun stats() = ServerStats(all) { clock }

    // --- ServerStats ----------------------------------------------------------------------

    @Test
    fun withNoDataItAsksTheFirstOfEachFamily() {
        assertEquals(listOf(v4a, v6a), stats().initial(all, ipv6Works = true))
    }

    @Test
    fun withoutIpv6ItAsksTheTwoBestIpv4() {
        assertEquals(listOf(v4a, v4b), stats().initial(all, ipv6Works = false))
    }

    @Test
    fun theFasterServerGoesFirst() {
        val s = stats()
        s.answered(v4a, 80)
        s.answered(v4b, 20)
        s.answered(v6a, 40)
        assertEquals(listOf(v4b, v6a), s.initial(all, true))
        assertEquals(listOf(v4b, v6a, v4a, v6b), s.order(all))
    }

    @Test
    fun aServerThatKeepsLosingGoesToTheBack() {
        val s = stats()
        s.answered(v4a, 30)
        s.missed(v4a)
        assertFalse(s.isLosing(v4a)) // una sola pérdida no basta
        s.missed(v4a)
        assertTrue(s.isLosing(v4a))
        assertEquals(v4a, s.order(all).last())
        assertEquals(v4b, s.initial(all, true)[0])
    }

    @Test
    fun aLosingIpv6SecondIsReplacedByTheNextBest() {
        val s = stats()
        s.missed(v6a); s.missed(v6a)
        assertEquals(listOf(v4a, v6b), s.initial(all, true))
        s.missed(v6b); s.missed(v6b)
        assertEquals(listOf(v4a, v4b), s.initial(all, true)) // ningún IPv6 sano: los dos mejores
    }

    @Test
    fun anAnswerClearsTheLossesAndTheyFadeWithTime() {
        val s = stats()
        s.missed(v4a); s.missed(v4a)
        s.answered(v4a, 50)
        assertFalse(s.isLosing(v4a))
        s.missed(v4b); s.missed(v4b)
        assertTrue(s.isLosing(v4b))
        clock += ServerStats.LOSS_MEMORY_MS + 1
        assertFalse(s.isLosing(v4b))
    }

    @Test
    fun hedgeDelayIsTwoAndAHalfTimesTheBestRttWithinBounds() {
        val s = stats()
        assertEquals(ServerStats.DEFAULT_HEDGE_MS, s.hedgeDelayMs(all)) // sin datos
        s.answered(v4a, 20)
        assertEquals(150L, s.hedgeDelayMs(all)) // 50 ms, sube al mínimo
        val s2 = stats()
        s2.answered(v4a, 100)
        assertEquals(250L, s2.hedgeDelayMs(all))
        val s3 = stats()
        s3.answered(v4a, 900)
        assertEquals(800L, s3.hedgeDelayMs(all)) // 2250 ms, baja al máximo
        s3.answered(v4b, 100) // el mejor manda, no el peor
        assertEquals(250L, s3.hedgeDelayMs(all))
    }

    @Test
    fun theRttIsSmoothedAndStaleSamplesAreForgotten() {
        val s = stats()
        s.answered(v4a, 100)
        s.answered(v4a, 20) // 100 + (20 - 100) / 8 = 90
        assertEquals(90.0, s.cost(v4a), 0.001)
        clock += ServerStats.SAMPLE_TTL_MS + 1
        assertEquals(ServerStats.UNKNOWN_RTT_MS, s.cost(v4a), 0.001)
    }

    @Test
    fun aNewNetworkForgetsTheRtt() {
        val s = stats()
        s.answered(v4a, 10)
        s.missed(v4a)
        s.reset(rtt = false)
        assertEquals(10.0, s.cost(v4a), 0.001)
        s.reset(rtt = true)
        assertEquals(ServerStats.UNKNOWN_RTT_MS, s.cost(v4a), 0.001)
    }

    @Test
    fun withFewerServersThanSlotsItReturnsThemAll() {
        val s = stats()
        assertEquals(listOf(v4a), s.initial(listOf(v4a), true))
        assertEquals(listOf(v6a), s.initial(listOf(v6a), false)) // sin IPv6 pero sin otra cosa: se usa
    }

    // --- StallDetector --------------------------------------------------------------------

    @Test
    fun sixConsecutiveExpiriesWithinTheWindowAreAStall() {
        val d = StallDetector(6, 10_000)
        for (i in 0 until 5) assertFalse(d.expired(sentAt = i * 100L, now = 4_000 + i * 100L, sendsWorked = true))
        assertTrue(d.expired(500, 4_500, true))
    }

    @Test
    fun expiriesSpreadOverMoreThanTheWindowAreNot() {
        val d = StallDetector(6, 10_000)
        for (i in 0 until 6) assertFalse(d.expired(i * 3_000L, 4_000 + i * 3_000L, true)) // 15 s entre la 1.ª y la 6.ª
    }

    @Test
    fun anAnswerCutsTheStreak() {
        val d = StallDetector(6, 10_000)
        repeat(5) { assertFalse(d.expired(0, 100L + it, true)) }
        d.answered()
        assertFalse(d.expired(0, 200, true))
        repeat(4) { assertFalse(d.expired(0, 300L + it, true)) }
        assertTrue(d.expired(0, 400, true))
    }

    @Test
    fun failedSendsMeanNoNetworkNotAStall() {
        val d = StallDetector(3, 10_000)
        repeat(10) { assertFalse(d.expired(0, 100L + it, sendsWorked = false)) }
    }

    @Test
    fun queriesSentBeforeTheLastStallDoNotCountTowardsTheNext() {
        val d = StallDetector(3, 10_000)
        assertFalse(d.expired(0, 1_000, true))
        assertFalse(d.expired(0, 1_001, true))
        assertTrue(d.expired(0, 1_002, true))
        // las demás que ya iban en vuelo caducan después: ya se atendieron en el atasco
        repeat(10) { assertFalse(d.expired(500, 1_003L + it, true)) }
        // las nuevas sí cuentan
        assertFalse(d.expired(1_100, 1_500, true))
        assertFalse(d.expired(1_100, 1_501, true))
        assertTrue(d.expired(1_100, 1_502, true))
    }

    @Test
    fun resetStartsFromScratch() {
        val d = StallDetector(2, 10_000)
        assertFalse(d.expired(0, 100, true))
        d.reset(150)
        assertFalse(d.expired(100, 200, true)) // salió antes del reinicio: no cuenta
        assertFalse(d.expired(160, 210, true))
        assertTrue(d.expired(160, 211, true))
    }

    // --- MinGap ---------------------------------------------------------------------------

    @Test
    fun minGapLetsOnePerWindowThrough() {
        var t = 0L
        val g = MinGap(60_000) { t }
        assertTrue(g.tryAcquire())
        t = 59_999
        assertFalse(g.tryAcquire())
        t = 60_000
        assertTrue(g.tryAcquire())
        assertFalse(g.tryAcquire())
    }

    // --- DefaultNetworkTracker ------------------------------------------------------------

    private val wifi = Caps(true, Transport.WIFI)
    private val cell = Caps(true, Transport.CELLULAR)

    private class Log {
        val changes = ArrayList<Int?>()
    }

    private fun tracker(log: Log) = DefaultNetworkTracker<Int> { log.changes += it }

    @Test
    fun aBackgroundCellularLinkFlappingOnWifiIsNotAChange() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to wifi, 2 to cell))
        assertEquals(1, t.current)
        repeat(3) {
            t.onLost(2)
            t.onAvailable(2, cell)
            t.onCaps(2, cell)
        }
        assertTrue("sin cambios, hubo ${log.changes}", log.changes.isEmpty())
        assertEquals(1, t.current)
    }

    @Test
    fun losingTheDefaultSwitchesToTheNextOne() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to wifi, 2 to cell))
        t.onLost(1)
        assertEquals(listOf<Int?>(2), log.changes)
        t.onAvailable(1, wifi) // vuelve el Wi-Fi: gana otra vez
        assertEquals(listOf<Int?>(2, 1), log.changes)
    }

    @Test
    fun validatedBeatsWifiThatIsNotValidated() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(2 to cell))
        t.onAvailable(1, Caps(false, Transport.WIFI)) // un Wi-Fi sin internet (portal, router sin salida)
        assertTrue(log.changes.isEmpty())
        t.onCaps(1, wifi) // ya validado
        assertEquals(listOf<Int?>(1), log.changes)
    }

    @Test
    fun ethernetBeatsWifiBeatsCellularAndTiesKeepTheCurrent() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to cell, 2 to wifi))
        assertEquals(2, t.current)
        t.onAvailable(3, Caps(true, Transport.ETHERNET))
        assertEquals(3, t.current)
        t.onAvailable(4, Caps(true, Transport.ETHERNET)) // empate: no se salta
        assertEquals(3, t.current)
        assertEquals(listOf<Int?>(3), log.changes)
    }

    @Test
    fun losingEverythingReportsNullAndComingBackReportsTheNetwork() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to wifi))
        t.onLost(1)
        t.onAvailable(1, wifi)
        assertEquals(listOf<Int?>(null, 1), log.changes)
    }

    @Test
    fun theSeedAndUnknownEventsAreNotChanges() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to wifi))
        t.onAvailable(1, wifi)
        t.onCaps(9, wifi) // red que no conocemos
        t.onLost(9)
        assertTrue(log.changes.isEmpty())
        assertNull(DefaultNetworkTracker<Int> {}.current)
    }

    @Test
    fun bestMatchingModeReportsOnlyRealChanges() {
        val log = Log()
        val t = tracker(log)
        t.seed(mapOf(1 to wifi))
        t.onBest(1) // el primer aviso del registro: la misma
        assertTrue(log.changes.isEmpty())
        t.onBest(2)
        t.onBestLost(1) // una que ya no era la mejor: nada
        assertEquals(listOf<Int?>(2), log.changes)
        t.onBestLost(2)
        assertEquals(listOf<Int?>(2, null), log.changes)
    }
}
