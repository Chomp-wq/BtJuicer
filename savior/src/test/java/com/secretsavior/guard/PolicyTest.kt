package com.secretsavior.guard

import com.secretsavior.guard.Policy.Grace
import com.secretsavior.guard.Policy.Surface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que importa del guardián, probado sin Android: que en Xiaomi y en cualquier idioma no se
 * llegue a «Forzar detención» / «Desinstalar» / «Borrar datos», sin romper lo que ya funcionaba.
 */
class PolicyTest {

    private val OURS = Concept.OURS

    private fun input(
        surface: Surface = Surface.SETTINGS,
        mask: Int = 0,
        kind: Int = 0,
        dangerId: Boolean = false,
        texts: Int = 10,
        autostartList: Boolean = false,
        strict: Boolean = false,
        grace: Grace? = null,
        adminActive: Boolean = true,
        privateDnsStrict: Boolean = false,
        vpnPermitted: Boolean = true,
        devBlocked: Boolean = false,
        recentOurs: Boolean = false,
        secondSpaceSurface: Boolean = false,
    ) = Policy.Input(
        surface, mask, kind, dangerId, texts, autostartList, strict, grace, adminActive,
        privateDnsStrict, vpnPermitted, devBlocked, recentOurs, secondSpaceSurface,
    )

    private fun closes(i: Policy.Input) = Policy.decide(i).close

    // --- Xiaomi: ficha de la app en la app de Seguridad ------------------------------------

    @Test
    fun xiaomiAppDetailsClosesByForceStopWordsInKnownLanguage() {
        val mask = OURS or Concept.FORCE_STOP or Concept.UNINSTALL
        assertTrue(closes(input(Surface.VENDOR, mask)))
    }

    @Test
    fun xiaomiAppDetailsClosesByWindowClassWithNoWords() {
        // Idioma raro, ni una palabra reconocida: la clase de la ventana y el nombre de la app bastan.
        assertTrue(closes(input(Surface.VENDOR, OURS, kind = WinKind.APP_DETAILS)))
    }

    @Test
    fun xiaomiAppDetailsClosesByButtonIdWithNoWords() {
        assertTrue(closes(input(Surface.VENDOR, OURS, dangerId = true)))
    }

    @Test
    fun xiaomiAppDetailsClosesInStrictLocaleEvenWithNothingElse() {
        assertTrue(closes(input(Surface.VENDOR, OURS, strict = true)))
    }

    @Test
    fun xiaomiAnyLanguageEndToEnd() {
        // Lo que el guardián lee de una ficha de Xiaomi en cada idioma incorporado: el nombre de la
        // app y los botones. Siempre se cierra.
        val buttons = mapOf(
            "es" to "Forzar detención", "en" to "Force stop", "fr" to "Forcer l’arrêt",
            "de" to "Beenden erzwingen", "ru" to "Принудительно остановить", "tr" to "Durmaya zorla",
            "zh" to "强行停止", "ja" to "強制停止", "ko" to "강제 중지", "ar" to "فرض الإيقاف",
            "pt" to "Forçar parada", "it" to "Forza arresto", "pl" to "Wymuś zatrzymanie",
            "hi" to "ज़बरदस्ती रोकें", "vi" to "Buộc dừng", "th" to "บังคับหยุด", "id" to "Paksa berhenti",
        )
        for ((lang, text) in buttons) {
            val l = Labels.build(lang, if (lang == "zh") "Hans" else "")
            val mask = l.mask("Secret Savior") or l.mask(text)
            assertTrue("$lang no cierra", closes(input(Surface.VENDOR, mask, strict = !l.known)))
        }
        // Y en un idioma sin traducción (sueco, sin lectura de Ajustes): modo estricto.
        val sv = Labels.build("sv")
        assertFalse(sv.known)
        assertTrue(closes(input(Surface.VENDOR, sv.mask("Secret Savior"), strict = !sv.known)))
    }

    @Test
    fun securityAppOptimizerListThatMentionsUsStaysUsableInKnownLocale() {
        // Regresión real: la lista del optimizador nombra la app y no debe cerrarse.
        assertFalse(closes(input(Surface.VENDOR, OURS, texts = 40)))
        val en = Labels.build("en")
        val mask = en.mask("Secret Savior") or en.mask("Clean master") or en.mask("Battery saver")
        assertFalse(closes(input(Surface.VENDOR, mask, texts = 40)))
    }

    @Test
    fun securityAppScreenWithoutUsIsLeftAlone() {
        assertFalse(closes(input(Surface.VENDOR, Concept.FORCE_STOP, kind = WinKind.APP_DETAILS)))
    }

    @Test
    fun autostartListClosesWhenLocked() {
        assertTrue(closes(input(Surface.VENDOR, 0, autostartList = true)))
        assertTrue(closes(input(Surface.VENDOR, OURS or Concept.AUTOSTART, autostartList = true, grace = Grace.AUTOSTART)))
    }

    @Test
    fun powerKeeperBackgroundRestrictionPageOfOursClosesUnlessBatteryGrace() {
        val mask = OURS or Concept.RESTRICT_BACKGROUND
        assertTrue(closes(input(Surface.VENDOR, mask)))
        assertTrue(closes(input(Surface.VENDOR, mask, grace = Grace.NOTIFICATION_ACCESS)))
        assertFalse(closes(input(Surface.VENDOR, mask, grace = Grace.BATTERY)))
    }

    @Test
    fun secondSpaceOfXiaomiCloses() {
        assertTrue(closes(input(Surface.VENDOR, Concept.USERS_SECOND_SPACE, secondSpaceSurface = true)))
        assertFalse(closes(input(Surface.VENDOR, Concept.USERS_SECOND_SPACE)))
    }

    @Test
    fun confirmationDialogAfterSeeingUsCloses() {
        val dialog = input(Surface.SETTINGS, Concept.FORCE_STOP, texts = 4, recentOurs = true)
        assertTrue(closes(dialog))
        assertFalse(closes(input(Surface.SETTINGS, Concept.FORCE_STOP, texts = 4, recentOurs = false)))
        assertFalse(closes(input(Surface.SETTINGS, Concept.FORCE_STOP, texts = 30, recentOurs = true)))
        // Una palabra genérica no basta para dar por buena la heurística.
        assertFalse(closes(input(Surface.SETTINGS, Concept.UNINSTALL_WEAK, texts = 4, recentOurs = true)))
    }

    // --- Ajustes ------------------------------------------------------------------------

    @Test
    fun settingsScreenNamingUsClosesWithoutGrace() {
        assertTrue(closes(input(Surface.SETTINGS, OURS)))
    }

    @Test
    fun noAdminMeansUserCanReachAdminActivation() {
        assertFalse(closes(input(Surface.SETTINGS, OURS, adminActive = false)))
        // Pero Accesibilidad no se abre nunca.
        assertTrue(closes(input(Surface.SETTINGS, 0, kind = WinKind.ACCESSIBILITY, adminActive = false)))
    }

    @Test
    fun accessibilityScreenByClassClosesInAnyLanguage() {
        assertTrue(closes(input(Surface.SETTINGS, 0, kind = WinKind.ACCESSIBILITY)))
        assertTrue(closes(input(Surface.VENDOR, 0, kind = WinKind.ACCESSIBILITY)))
    }

    @Test
    fun accessibilityNeverAllowedInGrace() {
        for (g in Grace.values()) {
            assertTrue("$g", closes(input(Surface.SETTINGS, OURS, kind = WinKind.ACCESSIBILITY, grace = g)))
            assertTrue("$g", closes(input(Surface.SETTINGS, OURS or Concept.ACCESSIBILITY, grace = g)))
        }
    }

    @Test
    fun deviceAdminAndAppDetailsNeverAllowedInGrace() {
        for (g in Grace.values()) {
            assertTrue("$g admin", closes(input(Surface.SETTINGS, OURS or Concept.DEACTIVATE_ADMIN, grace = g)))
            assertTrue("$g admin clase", closes(input(Surface.SETTINGS, OURS, kind = WinKind.ADMIN, grace = g)))
        }
        for (g in listOf(Grace.BATTERY, Grace.AUTOSTART, Grace.NOTIFICATION_ACCESS, Grace.ALWAYS_ON_VPN)) {
            assertTrue("$g ficha", closes(input(Surface.SETTINGS, OURS or Concept.FORCE_STOP, grace = g)))
            assertTrue("$g ficha clase", closes(input(Surface.SETTINGS, OURS, kind = WinKind.APP_DETAILS, grace = g)))
            assertTrue("$g id", closes(input(Surface.SETTINGS, OURS, dangerId = true, grace = g)))
            assertTrue("$g genérica", closes(input(Surface.SETTINGS, OURS or Concept.UNINSTALL_WEAK, grace = g)))
        }
    }

    @Test
    fun batteryGraceLetsOursBatteryScreenThrough() {
        assertFalse(closes(input(Surface.SETTINGS, OURS, grace = Grace.BATTERY)))
        // Pero una lista de batería que también ofrece «Forzar detención» no.
        assertTrue(closes(input(Surface.SETTINGS, OURS or Concept.FORCE_STOP, grace = Grace.BATTERY)))
        // Y una pantalla de VPN tampoco, con la ventana de batería.
        assertTrue(closes(input(Surface.SETTINGS, OURS or Concept.VPN, grace = Grace.BATTERY)))
        assertTrue(closes(input(Surface.SETTINGS, OURS, kind = WinKind.VPN, grace = Grace.BATTERY)))
    }

    @Test
    fun notificationAccessGraceLetsListAndDetailThrough() {
        assertFalse(closes(input(Surface.SETTINGS, OURS, kind = WinKind.NOTIFICATION_ACCESS, grace = Grace.NOTIFICATION_ACCESS)))
        // La fila que nombra a la app no se tapa, para poder encender el interruptor.
        val v = Policy.decide(input(Surface.SETTINGS, OURS, grace = Grace.NOTIFICATION_ACCESS))
        assertFalse(v.shieldOurs)
        // Sin ventana, sí.
        assertTrue(closes(input(Surface.SETTINGS, OURS, kind = WinKind.NOTIFICATION_ACCESS)))
    }

    @Test
    fun alwaysOnVpnGraceAllowsVpnScreenWithShieldsOverForgetAndLockdown() {
        val i = input(Surface.SETTINGS, OURS or Concept.VPN or Concept.VPN_DISCONNECT_FORGET or Concept.LOCKDOWN_TOGGLE, grace = Grace.ALWAYS_ON_VPN)
        val v = Policy.decide(i)
        assertFalse(v.close)
        assertTrue(v.shield and Concept.VPN_DISCONNECT_FORGET != 0)
        assertTrue(v.shield and Concept.LOCKDOWN_TOGGLE != 0)
        assertTrue(v.shield and Concept.STRONG == Concept.STRONG)
        // Sin la gracia, la pantalla de VPN que nombra a la app se cierra, como siempre.
        assertTrue(closes(input(Surface.SETTINGS, OURS or Concept.VPN, kind = WinKind.VPN)))
        // En un idioma que no se conoce no se puede tapar «Bloquear conexiones sin VPN»: no se abre.
        assertTrue(closes(input(Surface.SETTINGS, OURS or Concept.VPN, grace = Grace.ALWAYS_ON_VPN, strict = true)))
    }

    @Test
    fun autoRevokeGraceAllowsPermissionsPageAndShieldsDangerRows() {
        val perms = input(Surface.PERMISSIONS, OURS, grace = Grace.AUTO_REVOKE)
        assertFalse(closes(perms))
        // La ficha de la app (retroceso si no hay página propia): se deja, con las filas tapadas.
        val details = input(Surface.SETTINGS, OURS or Concept.FORCE_STOP or Concept.UNINSTALL or Concept.CLEAR_DATA, kind = WinKind.APP_DETAILS, grace = Grace.AUTO_REVOKE)
        val v = Policy.decide(details)
        assertFalse(v.close)
        assertTrue(v.shield and Concept.STRONG == Concept.STRONG)
        assertTrue(v.shieldIds)
        // El interruptor «eliminar permisos si no se usa» no se tapa con palabras genéricas.
        assertEquals(0, v.shield and Concept.WEAK)
        // En idioma desconocido la ficha no se puede tapar por texto: se cierra.
        assertTrue(closes(input(Surface.SETTINGS, OURS, kind = WinKind.APP_DETAILS, grace = Grace.AUTO_REVOKE, strict = true)))
        // Nunca administrador ni Accesibilidad.
        assertTrue(closes(input(Surface.SETTINGS, OURS or Concept.DEACTIVATE_ADMIN, grace = Grace.AUTO_REVOKE)))
    }

    @Test
    fun graceWithoutOursDoesNotChangeOtherRules() {
        assertFalse(closes(input(Surface.SETTINGS, 0, grace = Grace.BATTERY)))
    }

    @Test
    fun privateDnsEditorClosesUnlessStrictAlready() {
        assertTrue(closes(input(Surface.SETTINGS, Concept.PRIVATE_DNS_EDITOR)))
        assertFalse(closes(input(Surface.SETTINGS, Concept.PRIVATE_DNS_EDITOR, privateDnsStrict = true)))
    }

    @Test
    fun proxyEditorClosesWhenLocked() {
        assertTrue(closes(input(Surface.SETTINGS, Concept.PROXY_EDITOR)))
        assertFalse(closes(input(Surface.SETTINGS, Concept.PROXY_EDITOR, adminActive = false)))
    }

    @Test
    fun usersScreenClosesByClassButMainRowStaysUsable() {
        assertTrue(closes(input(Surface.SETTINGS, 0, kind = WinKind.USERS)))
        assertFalse(closes(input(Surface.SETTINGS, Concept.VPN)))
        // La fila de Ajustes «Usuarios y cuentas» sólo se tapa si lleva una frase precisa.
        val es = Labels.build("es")
        assertEquals(0, es.mask("Usuarios y cuentas") and Concept.USERS_SECOND_SPACE)
        val v = Policy.decide(input(Surface.SETTINGS, es.mask("Añadir usuario")))
        assertTrue(v.shield and Concept.USERS_SECOND_SPACE != 0)
    }

    @Test
    fun developerOptionsOnlyWhenBlocked() {
        assertFalse(closes(input(Surface.SETTINGS, 0, kind = WinKind.DEV)))
        assertTrue(closes(input(Surface.SETTINGS, 0, kind = WinKind.DEV, devBlocked = true)))
        assertEquals(0, Policy.decide(input(Surface.SETTINGS, 0)).shield and Concept.BUILD_NUMBER)
        val v = Policy.decide(input(Surface.SETTINGS, 0, devBlocked = true))
        assertTrue(v.shield and Concept.DEVELOPER_OPTIONS != 0)
        assertTrue(v.shield and Concept.BUILD_NUMBER != 0)
    }

    @Test
    fun accessibilityRowsAreAlwaysShielded() {
        val v = Policy.decide(input(Surface.SETTINGS, Concept.ACCESSIBILITY))
        assertTrue(v.shield and Concept.ACCESSIBILITY != 0)
    }

    // --- cubierta ------------------------------------------------------------------------

    @Test
    fun coverStaysWhileScreenHasNotLoaded() {
        assertTrue(Policy.decide(input(Surface.VENDOR, 0, texts = 1)).keepCover)
        assertTrue(Policy.decide(input(Surface.SETTINGS, 0, texts = Policy.LOADED_TEXTS - 1)).keepCover)
        assertFalse(Policy.decide(input(Surface.SETTINGS, 0, texts = Policy.LOADED_TEXTS)).keepCover)
        // Si se cierra, no hay nada que esperar.
        assertFalse(Policy.decide(input(Surface.VENDOR, OURS, strict = true, texts = 1)).keepCover)
    }

    @Test
    fun installerAndDialogsHaveNoCover() {
        assertFalse(Policy.decide(input(Surface.INSTALLER, 0, texts = 1)).keepCover)
    }

    // --- instalador y diálogos de VPN ---------------------------------------------------------

    @Test
    fun updateThroughPackageInstallerStillInstalls() {
        // La pantalla de actualizar nombra a la app y, en un idioma raro, no dice nada reconocible.
        assertFalse(closes(input(Surface.INSTALLER, OURS or Concept.VPN)))
        assertFalse(closes(input(Surface.INSTALLER, OURS, strict = true)))
        assertFalse(closes(input(Surface.INSTALLER, OURS, strict = true, kind = 0)))
        val en = Labels.build("en")
        val mask = en.mask("Do you want to install an update to this existing application? Secret Savior")
        assertFalse(closes(input(Surface.INSTALLER, mask)))
    }

    @Test
    fun uninstallThroughPackageInstallerCloses() {
        assertTrue(closes(input(Surface.INSTALLER, OURS or Concept.UNINSTALL)))
        assertTrue(closes(input(Surface.INSTALLER, OURS, kind = WinKind.UNINSTALL, strict = true)))
        assertTrue(closes(input(Surface.INSTALLER, OURS, dangerId = true, strict = true)))
        // Sin pasar por Ajustes ni administrador: no hay puerta de «sin administrador».
        assertTrue(closes(input(Surface.INSTALLER, Concept.UNINSTALL, adminActive = false)))
    }

    @Test
    fun vpnDialogs() {
        assertTrue(closes(input(Surface.VPN_DIALOGS, OURS, vpnPermitted = true)))
        assertFalse(closes(input(Surface.VPN_DIALOGS, OURS, vpnPermitted = false)))
        assertFalse(closes(input(Surface.VPN_DIALOGS, 0, vpnPermitted = true)))
    }

    // --- cierre por el aviso de la ventana -------------------------------------------------------

    private fun event(
        settingsLike: Boolean = true,
        titleMask: Int = 0,
        kind: Int = 0,
        usersTitle: Boolean = false,
        adminActive: Boolean = true,
        grace: Grace? = null,
        strict: Boolean = false,
        devBlocked: Boolean = false,
    ) = Policy.eventClose(settingsLike, titleMask, kind, usersTitle, adminActive, grace, strict, devBlocked)

    @Test
    fun eventTitleNamingUsClosesWithoutGrace() {
        assertTrue(event(titleMask = OURS))
        assertFalse(event(titleMask = OURS, adminActive = false))
        assertFalse(event(titleMask = OURS, grace = Grace.BATTERY))
        assertTrue(event(titleMask = OURS, kind = WinKind.APP_DETAILS, grace = Grace.BATTERY))
    }

    @Test
    fun eventAccessibilityByTitleOrClassNeverGraced() {
        assertTrue(event(titleMask = Concept.ACCESSIBILITY, grace = Grace.BATTERY, adminActive = false))
        assertTrue(event(kind = WinKind.ACCESSIBILITY, grace = Grace.AUTO_REVOKE, adminActive = false))
        // La clase sólo cuenta en Ajustes/fabricante.
        assertFalse(event(settingsLike = false, kind = WinKind.ACCESSIBILITY))
    }

    @Test
    fun eventUsersAndDeveloper() {
        assertTrue(event(kind = WinKind.USERS))
        assertTrue(event(usersTitle = true))
        assertFalse(event(titleMask = Concept.DEVELOPER_OPTIONS))
        assertTrue(event(titleMask = Concept.DEVELOPER_OPTIONS, devBlocked = true))
        assertTrue(event(kind = WinKind.DEV, devBlocked = true))
        assertFalse(event(kind = WinKind.DEV))
    }

    @Test
    fun nothingHappensOnUnrelatedScreens() {
        assertFalse(event())
        assertFalse(closes(input(Surface.SETTINGS, Concept.VPN)))
        assertFalse(closes(input(Surface.PERMISSIONS, 0)))
    }
}
