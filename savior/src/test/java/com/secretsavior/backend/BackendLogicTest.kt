package com.secretsavior.backend

import com.secretsavior.guard.A11yList
import com.secretsavior.guard.OwnerPolicy
import com.secretsavior.guard.SuspendGate
import com.secretsavior.guard.SuspendGate.Action
import com.secretsavior.guard.Throttle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackendLogicTest {

    private val me = "com.secretsavior/com.secretsavior.guard.GuardService"

    // --- accesibilidad ---

    @Test fun mergeIntoEmptyAndNull() {
        assertEquals(me, A11yList.merge(null, me))
        assertEquals(me, A11yList.merge("", me))
        assertEquals(me, A11yList.merge(":", me))
    }

    @Test fun mergeKeepsOthersAndAppends() {
        assertEquals("a/b.C:$me", A11yList.merge("a/b.C", me))
        assertEquals("a/b.C:x/y.Z:$me", A11yList.merge("a/b.C:x/y.Z:", me))
    }

    @Test fun mergeDoesNotDuplicate() {
        val cur = "a/b.C:$me"
        assertEquals(cur, A11yList.merge(cur, me))
        assertEquals(cur.uppercase(), A11yList.merge(cur.uppercase(), me))
    }

    @Test fun shortClassFormIsRecognised() {
        val cur = "com.secretsavior/.guard.GuardService"
        assertTrue(A11yList.contains(cur, me))
        assertEquals(cur, A11yList.merge(cur, me))
    }

    @Test fun isGuardEnabledStyleCheckAcceptsPersistedShortForm() {
        // Lo que guarda AccessibilityManagerService: Status.isGuardEnabled debe verlo como activo.
        assertTrue(A11yList.contains("x/y.Z:com.secretsavior/.guard.GuardService:", me))
        assertFalse(A11yList.contains("x/y.Z", me))
    }

    @Test fun similarServiceIsNotOurs() {
        assertFalse(A11yList.contains("com.secretsavior/com.secretsavior.guard.GuardService2", me))
        assertFalse(A11yList.contains("other.com.secretsavior/com.secretsavior.guard.GuardService", me))
    }

    // --- restricciones ---

    @Test fun restrictionsByApiLevel() {
        val r26 = OwnerPolicy.restrictions(26, false)
        assertTrue(OwnerPolicy.SAFE_BOOT in r26 && OwnerPolicy.FACTORY_RESET in r26 && OwnerPolicy.ADD_USER in r26)
        assertTrue(OwnerPolicy.CONFIG_VPN in r26 && OwnerPolicy.ADD_MANAGED_PROFILE in r26)
        assertFalse(OwnerPolicy.USER_SWITCH in r26)
        assertFalse(OwnerPolicy.CONFIG_PRIVATE_DNS in r26)

        val r28 = OwnerPolicy.restrictions(28, false)
        assertTrue(OwnerPolicy.USER_SWITCH in r28)
        assertFalse(OwnerPolicy.CONFIG_PRIVATE_DNS in r28)

        val r35 = OwnerPolicy.restrictions(35, false)
        assertTrue(OwnerPolicy.CONFIG_PRIVATE_DNS in r35 && OwnerPolicy.USER_SWITCH in r35)
        assertEquals(r35.size, r35.toSet().size)
    }

    @Test fun adbOnlyWhenBlocked() {
        assertFalse(OwnerPolicy.DEBUGGING in OwnerPolicy.restrictions(35, false))
        assertTrue(OwnerPolicy.DEBUGGING in OwnerPolicy.restrictions(35, true))
    }

    @Test fun neverLocksEveryApp() {
        val all = OwnerPolicy.restrictions(35, true)
        assertFalse("no_control_apps" in all)
        assertFalse("no_install_unknown_sources" in all)
    }

    // --- suspensión de navegadores ---

    private fun run(steps: List<Triple<Long, Boolean, Boolean>>, eligible: Boolean = true): List<Action> {
        var since = SuspendGate.NOT_BROKEN
        var suspended = false
        val out = ArrayList<Action>()
        for ((t, broken, _) in steps) {
            val d = SuspendGate.decide(eligible, broken, since, t, suspended)
            since = d.brokenSince
            if (d.action == Action.SUSPEND) suspended = true
            if (d.action == Action.LIFT) suspended = false
            out += d.action
        }
        return out
    }

    @Test fun suspendsOnlyAfterTwentySecondsContinuous() {
        val a = run(listOf(Triple(0L, true, false), Triple(19_999L, true, false), Triple(20_000L, true, false)))
        assertEquals(listOf(Action.NONE, Action.NONE, Action.SUSPEND), a)
    }

    @Test fun blipResetsTheClock() {
        val a = run(
            listOf(
                Triple(0L, true, false), Triple(15_000L, false, false),
                Triple(16_000L, true, false), Triple(30_000L, true, false), Triple(36_000L, true, false),
            ),
        )
        assertEquals(listOf(Action.NONE, Action.NONE, Action.NONE, Action.NONE, Action.SUSPEND), a)
    }

    @Test fun liftsAsSoonAsProtectionIsBack() {
        val a = run(listOf(Triple(0L, true, false), Triple(25_000L, true, false), Triple(26_000L, false, false), Triple(27_000L, false, false)))
        assertEquals(listOf(Action.NONE, Action.SUSPEND, Action.LIFT, Action.NONE), a)
    }

    @Test fun suspendsOnceWhileStillBroken() {
        val a = run(listOf(Triple(0L, true, false), Triple(21_000L, true, false), Triple(60_000L, true, false)))
        assertEquals(listOf(Action.NONE, Action.SUSPEND, Action.NONE), a)
    }

    @Test fun liftsWhenNoLongerEligibleEvenIfBroken() {
        val d = SuspendGate.decide(eligible = false, broken = true, brokenSince = 0, now = 99_000, suspended = true)
        assertEquals(Action.LIFT, d.action)
        assertEquals(Action.NONE, SuspendGate.decide(false, true, 0, 99_000, false).action)
    }

    @Test fun staleSuspendedSetIsLiftedWhenFine() {
        // aunque el proceso acabe de nacer y no recuerde nada, lo guardado en disco se levanta
        val d = SuspendGate.decide(true, false, SuspendGate.NOT_BROKEN, 5, true)
        assertEquals(Action.LIFT, d.action)
    }

    @Test fun targetsExcludeProtectedAndMissing() {
        val t = SuspendGate.targets(
            setOf("com.android.chrome", "org.mozilla.firefox", "com.launcher.browser", "not.installed"),
            setOf("com.launcher.browser"),
        ) { it != "not.installed" }
        assertEquals(listOf("com.android.chrome", "org.mozilla.firefox"), t)
    }

    // --- aviso con límite ---

    @Test fun throttleSpacesCalls() {
        val t = Throttle(1_000)
        assertTrue(t.tryPass(0))
        assertFalse(t.tryPass(999))
        assertTrue(t.tryPass(1_000))
        assertFalse(t.tryPass(1_500))
    }
}
