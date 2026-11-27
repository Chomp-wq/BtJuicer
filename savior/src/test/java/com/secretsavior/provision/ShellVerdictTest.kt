package com.secretsavior.provision

import com.secretsavior.provision.ShellVerdict.Goal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellVerdictTest {

    @Test
    fun verifiedWinsOverText() {
        val v = ShellVerdict.interpret(Goal.DEVICE_OWNER, "Trying to set the device owner, but device owner is already set.", true)
        assertTrue(v.ok)
    }

    @Test
    fun accountsAreExplained() {
        val v = ShellVerdict.interpret(
            Goal.DEVICE_OWNER,
            "java.lang.IllegalStateException: Not allowed to set the device owner because there are already some accounts on the device",
            false,
        )
        assertFalse(v.ok)
        assertTrue(v.message.contains("Cuentas"))
    }

    @Test
    fun severalUsersAreExplained() {
        val v = ShellVerdict.interpret(Goal.DEVICE_OWNER, "...because there are already several users on the device", false)
        assertFalse(v.ok)
        assertTrue(v.message.contains("Segundo espacio"))
    }

    @Test
    fun xiaomiSecurityExceptionPointsToSecurityDebugging() {
        for (perm in listOf("GRANT_RUNTIME_PERMISSIONS", "MANAGE_DEVICE_ADMINS", "WRITE_SECURE_SETTINGS")) {
            val v = ShellVerdict.interpret(
                Goal.SECURE_SETTINGS,
                "Exception occurred while executing 'grant': java.lang.SecurityException: Neither user 2000 nor current process has android.permission.$perm.",
                false,
            )
            assertFalse(v.ok)
            assertTrue(perm, v.message.contains("ajustes de seguridad"))
        }
    }

    @Test
    fun otherOwnerAlreadySet() {
        val v = ShellVerdict.interpret(Goal.DEVICE_OWNER, "Trying to set the device owner (x), but device owner is already set.", false)
        assertFalse(v.ok)
        assertTrue(v.message.contains("otra app"))
    }

    @Test
    fun unknownOutputKeepsTheRawText() {
        val v = ShellVerdict.interpret(Goal.SECURE_SETTINGS, "algo raro", false)
        assertFalse(v.ok)
        assertTrue(v.message.contains("algo raro"))
        assertEquals("No se aplicó el cambio.", ShellVerdict.interpret(Goal.SECURE_SETTINGS, "", false).message)
    }

    @Test
    fun commandsAreTheDocumentedOnes() {
        assertEquals("pm grant com.secretsavior android.permission.WRITE_SECURE_SETTINGS", ShellVerdict.command(Goal.SECURE_SETTINGS))
        assertEquals("adb shell dpm set-device-owner com.secretsavior/.guard.AdminReceiver", ShellVerdict.pcCommand(Goal.DEVICE_OWNER))
    }

    @Test
    fun pairingCodeNeedsSixDigits() {
        assertEquals("123456", ShellVerdict.parseCode(" 123 456 "))
        assertNull(ShellVerdict.parseCode("12345"))
        assertNull(ShellVerdict.parseCode("1234567"))
        assertNull(ShellVerdict.parseCode(null))
    }
}
