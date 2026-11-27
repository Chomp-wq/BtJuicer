package com.secretsavior.guard

import androidx.core.content.UnusedAppRestrictionsConstants as U
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupLogicTest {
    @Test
    fun `reconoce encendido y apagado en varios idiomas`() {
        for (t in listOf("Activado", "ON", "Enabled", "已开启", "Encendido", "Включено", "켜짐")) {
            assertEquals(t, true, SwitchText.says(t))
        }
        for (t in listOf("Desactivado", "Off", "Disabled", "未开启", "已关闭", "Apagado", "Выключено")) {
            assertEquals(t, false, SwitchText.says(t))
        }
    }

    @Test
    fun `desactivado no cuenta como activado`() {
        assertEquals(false, SwitchText.says("desactivado"))
        assertEquals(false, SwitchText.says("Secret Savior: no activado, off"))
    }

    @Test
    fun `texto sin estado no dice nada`() {
        assertNull(SwitchText.says(null))
        assertNull(SwitchText.says(""))
        assertNull(SwitchText.says("Secret Savior"))
        assertNull(SwitchText.says("Autoencendido"))
    }

    @Test
    fun `isChecked manda y los textos completan`() {
        assertTrue(SwitchText.isOn(true, "Desactivado"))
        assertTrue(SwitchText.isOn(false, null, "Activado", null))
        assertFalse(SwitchText.isOn(false, "Activado", "Apagado"))
        assertFalse(SwitchText.isOn(false, null, null))
        assertFalse(SwitchText.isOn(false))
    }

    @Test
    fun `estado de pausa por inactividad`() {
        assertTrue(UnusedApps.isDone(U.FEATURE_NOT_AVAILABLE))
        assertTrue(UnusedApps.isDone(U.DISABLED))
        assertFalse(UnusedApps.isDone(U.API_30_BACKPORT))
        assertFalse(UnusedApps.isDone(U.API_30))
        assertFalse(UnusedApps.isDone(U.API_31))
        assertTrue(UnusedApps.isDone(U.ERROR))
        assertTrue(UnusedApps.isDone(null))
        assertTrue(UnusedApps.isDone(99))
    }
}
