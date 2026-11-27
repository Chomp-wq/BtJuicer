package com.secretsavior.guard

import java.util.concurrent.CancellationException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SafeTest {
    private val logged = ArrayList<String>()

    @Before
    fun setUp() {
        Safe.resetForTest()
        logged.clear()
        Safe.sink = { _, msg, _ -> logged += msg }
    }

    @After
    fun tearDown() {
        Safe.resetForTest()
    }

    @Test
    fun `atrapa Error y Exception`() {
        safely("a") { throw NoSuchMethodError("x") }
        safely("b") { throw SecurityException("x") }
        assertEquals(2, logged.size)
    }

    @Test
    fun `el valor de reserva se devuelve al fallar`() {
        assertEquals(7, safelyOr("c", 7) { error("x") })
        assertEquals(3, safelyOr("c", 7) { 3 })
    }

    @Test
    fun `registra una vez por sitio y clase de fallo`() {
        repeat(50) { safely("d") { throw IllegalStateException() } }
        assertEquals(1, logged.size)
        safely("d") { throw IllegalArgumentException() }
        safely("e") { throw IllegalStateException() }
        assertEquals(3, logged.size)
    }

    @Test
    fun `la cancelacion de corrutinas se propaga`() {
        try {
            safely("f") { throw CancellationException() }
            throw AssertionError("debía propagarse")
        } catch (_: CancellationException) {
        }
        assertTrue(logged.isEmpty())
    }

    @Test
    fun `un sumidero que falla no rompe nada`() {
        Safe.sink = { _, _, _ -> throw RuntimeException("log roto") }
        safely("g") { throw IllegalStateException() }
    }

    @Test
    fun `el hilo principal delega y los demas se tragan`() {
        assertEquals(UncaughtPolicy.Action.DELEGATE, UncaughtPolicy.decide(true))
        assertEquals(UncaughtPolicy.Action.SWALLOW, UncaughtPolicy.decide(false))
    }

    @Test
    fun `los hilos del tunel y del DNS reinician el proceso`() {
        assertEquals(UncaughtPolicy.Action.DELEGATE, UncaughtPolicy.decide(false, "savior-tun"))
        assertEquals(UncaughtPolicy.Action.DELEGATE, UncaughtPolicy.decide(false, "savior-dns-2"))
        assertEquals(UncaughtPolicy.Action.SWALLOW, UncaughtPolicy.decide(false, "savior-guard-bg"))
        assertEquals(UncaughtPolicy.Action.SWALLOW, UncaughtPolicy.decide(false, "savior-provision"))
    }

    @Test
    fun `los hilos llevan nombre`() {
        val f = NamedThreads("savior-x")
        val a = f.newThread {}
        val b = f.newThread {}
        assertEquals("savior-x", a.name)
        assertEquals("savior-x-2", b.name)
        assertFalse(a === b)
    }
}
