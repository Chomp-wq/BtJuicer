package com.secretsavior.guard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelsTest {

    private fun has(l: Labels, text: String, bit: Int) = l.mask(text) and bit != 0

    @Test
    fun normalizeFoldsCaseAccentsAndSpaces() {
        assertEquals("forcarparada", Fold.normalize("Forçar Parada"))
        assertEquals("forcerlarret", Fold.normalize("Forcer l’arrêt"))
        assertEquals("miui版本", Fold.normalize("MIUI 版本"))
        assertEquals("", Fold.normalize(null))
    }

    @Test
    fun languageKeys() {
        assertEquals(listOf("fr", "es", "en"), Labels.languageKeys("fr"))
        assertEquals(listOf("es", "en"), Labels.languageKeys("es"))
        assertEquals(listOf("zh-Hant", "es", "en"), Labels.languageKeys("zh", "", "TW"))
        assertEquals(listOf("zh-Hans", "es", "en"), Labels.languageKeys("zh", "Hans", "CN"))
        assertEquals(listOf("zh-Hant", "zh-Hans", "es", "en"), Labels.languageKeys("zh"))
        assertEquals("he", Labels.languageKeys("iw").first())
        assertEquals("id", Labels.languageKeys("in").first())
    }

    @Test
    fun everyRequiredLanguageHasBuiltins() {
        val required = listOf(
            "es", "en", "pt", "fr", "de", "it", "nl", "pl", "ru", "uk", "tr", "ro", "cs", "hu", "el",
            "ar", "he", "fa", "hi", "id", "ms", "vi", "th", "zh-Hans", "zh-Hant", "ja", "ko",
        )
        for (k in required) {
            val block = Labels.builtinBlock(k)
            assertTrue("falta $k", block != null)
            val pats = ArrayList<Pair<String, Int>>()
            val titles = HashSet<String>()
            Labels.parse(block!!, pats, titles)
            val covered = pats.fold(0) { acc, p -> acc or p.second }
            for (c in listOf(
                Concept.FORCE_STOP, Concept.UNINSTALL, Concept.CLEAR_DATA, Concept.ACCESSIBILITY,
                Concept.DEACTIVATE_ADMIN, Concept.VPN_DISCONNECT_FORGET, Concept.USERS_SECOND_SPACE,
                Concept.DEVELOPER_OPTIONS, Concept.BUILD_NUMBER, Concept.PRIVATE_DNS_EDITOR,
                Concept.PROXY_EDITOR, Concept.RESTRICT_BACKGROUND, Concept.LOCKDOWN_TOGGLE,
            )) {
                assertTrue("$k no cubre el concepto $c", covered and c != 0)
            }
            assertTrue("$k sin títulos de usuarios", titles.isNotEmpty())
        }
    }

    @Test
    fun everyBuiltinPhraseMatchesItself() {
        // Si una frase no se reconoce a sí misma, el plegado y el autómata no están de acuerdo.
        for (k in Labels.BUILTIN_LANGUAGES) {
            val pats = ArrayList<Pair<String, Int>>()
            Labels.parse(Labels.builtinBlock(k)!!, pats, HashSet())
            for ((p, bit) in pats) {
                val m = Matcher(listOf(p to bit))
                assertEquals("$k: «$p»", bit, m.scan(p))
                assertEquals("$k: «$p» en mayúsculas", bit, m.scan(p.uppercase()))
            }
        }
    }

    @Test
    fun forceStopInRealLanguages() {
        val cases = listOf(
            Triple("fr", "", "Forcer l’arrêt"),
            Triple("de", "", "Beenden erzwingen"),
            Triple("es", "", "Forzar detención"),
            Triple("pt", "", "Forçar parada"),
            Triple("it", "", "Forza arresto"),
            Triple("nl", "", "Forceer stop"),
            Triple("pl", "", "Wymuś zatrzymanie"),
            Triple("ru", "", "Принудительно остановить"),
            Triple("uk", "", "Примусово зупинити"),
            Triple("tr", "", "Durmaya zorla"),
            Triple("ro", "", "Oprire forțată"),
            Triple("cs", "", "Vynutit zastavení"),
            Triple("hu", "", "Kényszerített leállítás"),
            Triple("el", "", "Αναγκαστική διακοπή"),
            Triple("ar", "", "فرض الإيقاف"),
            Triple("he", "", "אילוץ עצירה"),
            Triple("fa", "", "توقف اجباری"),
            Triple("hi", "", "ज़बरदस्ती रोकें"),
            Triple("id", "", "Paksa berhenti"),
            Triple("ms", "", "Paksa henti"),
            Triple("vi", "", "Buộc dừng"),
            Triple("th", "", "บังคับหยุด"),
            Triple("zh", "Hans", "强行停止"),
            Triple("zh", "Hant", "強制停止"),
            Triple("ja", "", "強制停止"),
            Triple("ko", "", "강제 중지"),
        )
        for ((lang, script, text) in cases) {
            val l = Labels.build(lang, script)
            assertTrue("$lang: $text", has(l, text, Concept.FORCE_STOP))
            assertTrue("$lang conocido", l.known)
        }
    }

    @Test
    fun accessibilityAndDeveloperOptionsInOtherLanguages() {
        val fr = Labels.build("fr")
        assertTrue(has(fr, "Accessibilité", Concept.ACCESSIBILITY))
        assertTrue(has(fr, "Options pour les développeurs", Concept.DEVELOPER_OPTIONS))
        val de = Labels.build("de")
        assertTrue(has(de, "Bedienungshilfen", Concept.ACCESSIBILITY))
        assertTrue(has(de, "Build-Nummer", Concept.BUILD_NUMBER))
        val zh = Labels.build("zh", "Hans")
        assertTrue(has(zh, "无障碍", Concept.ACCESSIBILITY))
        assertTrue(has(zh, "MIUI版本", Concept.BUILD_NUMBER))
        val ru = Labels.build("ru")
        assertTrue(has(ru, "Специальные возможности", Concept.ACCESSIBILITY))
    }

    @Test
    fun oursIsLanguageIndependent() {
        for (lang in listOf("fr", "zh", "ar", "sv", "")) {
            val l = Labels.build(lang)
            assertTrue(has(l, "Secret Savior", Concept.OURS))
            assertTrue(has(l, "com.secretsavior", Concept.OURS))
            assertTrue(has(l, "SECRET SAVIOR", Concept.OURS))
        }
        // Y con el nombre localizado de la app.
        val l = Labels.build("fr", appLabel = "Sauveur secret")
        assertTrue(has(l, "Sauveur secret", Concept.OURS))
    }

    @Test
    fun plainUsersTitleIsExactOnlyAndMainRowIsNotMatched() {
        val es = Labels.build("es")
        assertTrue(es.isUsersTitle("Usuarios"))
        assertTrue(es.isUsersTitle("Varios usuarios"))
        assertFalse(es.isUsersTitle("Usuarios y cuentas"))
        assertEquals(0, es.mask("Usuarios y cuentas") and Concept.USERS_SECOND_SPACE)
        assertEquals(0, es.mask("Usuarios") and Concept.USERS_SECOND_SPACE)
        assertTrue(has(es, "Añadir usuario", Concept.USERS_SECOND_SPACE))
        assertTrue(has(es, "Segundo espacio", Concept.USERS_SECOND_SPACE))
        val en = Labels.build("en")
        assertEquals(0, en.mask("Users & accounts") and Concept.USERS_SECOND_SPACE)
        assertTrue(has(en, "Add guest", Concept.USERS_SECOND_SPACE))
    }

    @Test
    fun weakWordsAreNotStrong() {
        val ru = Labels.build("ru")
        // «Удалить» (genérico) sólo cuenta como desinstalar «débil».
        assertEquals(0, ru.mask("Удалить") and Concept.UNINSTALL)
        assertTrue(has(ru, "Удалить", Concept.UNINSTALL_WEAK))
        val en = Labels.build("en")
        assertEquals(0, en.mask("Clear cache") and Concept.CLEAR_DATA)
        assertTrue(has(en, "Clear data", Concept.CLEAR_DATA))
        assertTrue(has(en, "Force stop", Concept.FORCE_STOP))
    }

    // --- modo estricto ---------------------------------------------------------------------

    @Test
    fun strictDecision() {
        assertTrue(Labels.decideKnown(hasBuiltin = true, runtimeForceStop = false))
        assertTrue(Labels.decideKnown(hasBuiltin = false, runtimeForceStop = true))
        assertFalse(Labels.decideKnown(hasBuiltin = false, runtimeForceStop = false))
    }

    @Test
    fun unknownLanguageIsStrictUntilSettingsAnswer() {
        assertFalse(Labels.build("sv").known)
        assertFalse(Labels.build("sv", lookup = { _, _ -> null }).known)
        val fake = ResLookup { pkg, name ->
            if (pkg == "com.android.settings" && name == "force_stop") "Tvinga stopp" else null
        }
        val sv = Labels.build("sv", lookup = fake)
        assertTrue(sv.known)
        assertTrue(has(sv, "Tvinga stopp", Concept.FORCE_STOP))
    }

    @Test
    fun builtinLanguagesAreKnownWithoutLookup() {
        assertTrue(Labels.build("es").known)
        assertTrue(Labels.build("en").known)
        assertTrue(Labels.build("ko").known)
        assertTrue(Labels.build("zh", "", "TW").known)
        assertFalse(Labels.build("fi").known)
    }

    @Test
    fun runtimeStringsFeedTheMatcherAndTitles() {
        val fake = ResLookup { _, name ->
            when (name) {
                "uninstall_text" -> "Avinstallera"
                "accessibility_settings" -> "Tillgänglighet"
                "user_settings_title" -> "Användare"
                "force_stop" -> "Tvinga stopp"
                "clear_user_data_text" -> "Rensa lagring"
                else -> null
            }
        }
        val l = Labels.build("sv", lookup = fake)
        assertTrue(has(l, "Avinstallera", Concept.UNINSTALL))
        assertTrue(has(l, "Tillgänglighet", Concept.ACCESSIBILITY))
        assertTrue(has(l, "Rensa lagring", Concept.CLEAR_DATA))
        assertTrue(l.isUsersTitle("Användare"))
        assertFalse(l.isUsersTitle("Användare och konton"))
    }

    @Test
    fun brokenLookupIsHarmless() {
        val boom = ResLookup { _, _ -> throw IllegalStateException("sin recursos") }
        val l = Labels.build("fr", lookup = boom)
        assertTrue(l.known)
        assertTrue(has(l, "Forcer l'arrêt", Concept.FORCE_STOP))
    }

    @Test
    fun runtimeStringsWithPlaceholdersOrTooShortAreIgnored() {
        assertFalse(Labels.usableRuntime("%1\$s"))
        assertFalse(Labels.usableRuntime("OK"))
        assertFalse(Labels.usableRuntime(""))
        assertTrue(Labels.usableRuntime("Uninstall"))
        assertTrue(Labels.usableRuntime("卸载"))
    }

    // --- señales que no son texto -------------------------------------------------------

    @Test
    fun dangerIds() {
        assertTrue(Labels.isDangerId("com.android.settings:id/force_stop_button"))
        assertTrue(Labels.isDangerId("com.miui.securitycenter:id/am_detail_Uninstall"))
        assertTrue(Labels.isDangerId("com.android.settings:id/clear_data"))
        assertTrue(Labels.isDangerId("x:id/ClearStorage_btn".replace("ClearStorage", "clear_storage")))
        assertFalse(Labels.isDangerId("com.android.settings:id/title"))
        assertFalse(Labels.isDangerId(null))
    }

    @Test
    fun windowKinds() {
        assertNotEquals(0, WinKind.of("com.android.settings.applications.InstalledAppDetails") and WinKind.APP_DETAILS)
        assertNotEquals(0, WinKind.of("com.miui.appmanager.ApplicationsDetailsActivity") and WinKind.APP_DETAILS)
        assertNotEquals(0, WinKind.of("com.android.settings.applications.appinfo.AppInfoDashboardFragment") and WinKind.APP_DETAILS)
        assertNotEquals(0, WinKind.of("com.android.settings.Settings\$AccessibilitySettingsActivity") and WinKind.ACCESSIBILITY)
        assertNotEquals(0, WinKind.of("com.android.settings.DeviceAdminAdd") and WinKind.ADMIN)
        assertNotEquals(0, WinKind.of("com.android.settings.Settings\$DevelopmentSettingsDashboardActivity") and WinKind.DEV)
        assertNotEquals(0, WinKind.of("com.android.settings.Settings\$UserSettingsActivity") and WinKind.USERS)
        assertNotEquals(0, WinKind.of("com.miui.securitycore.SecondSpaceActivity") and WinKind.USERS)
        assertNotEquals(0, WinKind.of("com.android.settings.vpn2.VpnSettings") and WinKind.VPN)
        assertNotEquals(0, WinKind.of("com.android.settings.notification.NotificationAccessSettings") and WinKind.NOTIFICATION_ACCESS)
        assertNotEquals(0, WinKind.of("com.miui.permcenter.autostart.AutoStartManagementActivity") and WinKind.AUTOSTART)
        assertNotEquals(0, WinKind.of("com.android.packageinstaller.UninstallerActivity") and WinKind.UNINSTALL)
        assertEquals(0, WinKind.of("com.android.settings.Settings\$WifiSettingsActivity"))
        assertEquals(0, WinKind.of("com.android.settings.Settings\$UserAndAccountDashboardActivity"))
        assertEquals(0, WinKind.of("com.android.packageinstaller.InstallStart"))
        assertEquals(0, WinKind.of(null))
    }

    @Test
    fun transientClasses() {
        assertTrue(WinKind.isTransient("android.app.AlertDialog"))
        assertTrue(WinKind.isTransient("androidx.appcompat.app.AlertDialog"))
        assertTrue(WinKind.isTransient("android.widget.FrameLayout"))
        assertFalse(WinKind.isTransient("com.android.settings.SubSettings"))
    }

    @Test
    fun containsIcIsCaseInsensitiveAndAllocationFree() {
        assertTrue(Labels.containsIc("AbcDEF", "cde"))
        assertFalse(Labels.containsIc("abc", "abcd"))
        assertFalse(Labels.containsIc(null, "a"))
    }

    @Test
    fun everyLanguageHasAWeakStopPhrase() {
        // «Aplicaciones activas» (Android 13+) sólo dice «Detener»/«Stop» junto a nuestro nombre.
        val weakStop = mapOf(
            "en" to "Stop", "hu" to "Leállítás", "el" to "Διακοπή", "ar" to "إيقاف", "he" to "עצירה",
            "fa" to "توقف", "id" to "Hentikan", "ms" to "Hentikan", "vi" to "Dừng", "th" to "หยุด",
        )
        for ((lang, word) in weakStop) {
            val m = Labels.build(lang).mask("Secret Savior $word")
            assertNotEquals("$lang", 0, m and Concept.OURS)
            assertNotEquals("$lang", 0, m and Concept.FORCE_STOP_WEAK)
        }
        for (k in Labels.BUILTIN_LANGUAGES) {
            val pats = ArrayList<Pair<String, Int>>()
            Labels.parse(Labels.builtinBlock(k)!!, pats, HashSet())
            val covered = pats.fold(0) { acc, p -> acc or p.second }
            assertNotEquals("$k sin «detener» genérico", 0, covered and Concept.FORCE_STOP_WEAK)
        }
    }

    @Test
    fun notificationAccessConceptAndApnClass() {
        assertNotEquals(0, Labels.build("es").mask("Acceso a notificaciones") and Concept.NOTIFICATION_ACCESS)
        assertNotEquals(0, Labels.build("en").mask("Notification access") and Concept.NOTIFICATION_ACCESS)
        assertNotEquals(0, WinKind.of("com.android.settings.network.apn.ApnEditor") and WinKind.APN)
        assertEquals(0, WinKind.of("com.android.settings.network.apn.ApnSettings") and WinKind.APN)
    }
}
