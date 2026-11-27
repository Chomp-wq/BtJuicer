package com.secretsavior.guard

import java.util.Locale

/** Los conceptos que el guardián reconoce en pantalla, como bits de una máscara. */
object Concept {
    const val FORCE_STOP = 1 shl 0
    const val UNINSTALL = 1 shl 1
    const val CLEAR_DATA = 1 shl 2
    const val ACCESSIBILITY = 1 shl 3
    const val DEACTIVATE_ADMIN = 1 shl 4
    const val VPN_DISCONNECT_FORGET = 1 shl 5
    const val USERS_SECOND_SPACE = 1 shl 6
    const val DEVELOPER_OPTIONS = 1 shl 7
    const val BUILD_NUMBER = 1 shl 8
    const val PRIVATE_DNS_EDITOR = 1 shl 9
    const val PROXY_EDITOR = 1 shl 10
    const val RESTRICT_BACKGROUND = 1 shl 11

    /** El nombre de la app o su paquete: no depende del idioma. */
    const val OURS = 1 shl 12

    /** «Bloquear conexiones sin VPN»: el interruptor que dejaría el teléfono sin internet. */
    const val LOCKDOWN_TOGGLE = 1 shl 13
    const val AUTOSTART = 1 shl 14

    /** La palabra «vpn», igual en todos los idiomas. */
    const val VPN = 1 shl 15

    /**
     * Palabras genéricas («Eliminar», «Остановить», «停止»): sólo cuentan en pantallas que ya
     * nombran a la app, y nunca bastan para cerrar la lista de un optimizador que la menciona.
     */
    const val FORCE_STOP_WEAK = 1 shl 16
    const val UNINSTALL_WEAK = 1 shl 17
    const val CLEAR_DATA_WEAK = 1 shl 18

    /** Sólo en candidatos a tapar: el id de la vista dice «force_stop», «uninstall»... */
    const val DANGER_ID = 1 shl 30

    const val STRONG = FORCE_STOP or UNINSTALL or CLEAR_DATA
    const val WEAK = FORCE_STOP_WEAK or UNINSTALL_WEAK or CLEAR_DATA_WEAK

    /** Nombre en los bloques de idioma -> bit. */
    val BY_NAME: Map<String, Int> = mapOf(
        "FORCE_STOP" to FORCE_STOP, "UNINSTALL" to UNINSTALL, "CLEAR_DATA" to CLEAR_DATA,
        "ACCESSIBILITY" to ACCESSIBILITY, "DEACTIVATE_ADMIN" to DEACTIVATE_ADMIN,
        "VPN_DISCONNECT_FORGET" to VPN_DISCONNECT_FORGET, "USERS_SECOND_SPACE" to USERS_SECOND_SPACE,
        "DEVELOPER_OPTIONS" to DEVELOPER_OPTIONS, "BUILD_NUMBER" to BUILD_NUMBER,
        "PRIVATE_DNS_EDITOR" to PRIVATE_DNS_EDITOR, "PROXY_EDITOR" to PROXY_EDITOR,
        "RESTRICT_BACKGROUND" to RESTRICT_BACKGROUND, "LOCKDOWN_TOGGLE" to LOCKDOWN_TOGGLE,
        "AUTOSTART" to AUTOSTART,
    )

    /** El bit «genérico» de un concepto, o el propio si no tiene (para los patrones con «~»). */
    fun weak(bit: Int): Int = when (bit) {
        FORCE_STOP -> FORCE_STOP_WEAK
        UNINSTALL -> UNINSTALL_WEAK
        CLEAR_DATA -> CLEAR_DATA_WEAK
        else -> bit
    }
}

/** Qué clase de pantalla es una ventana, por el nombre de su clase (no depende del idioma). */
object WinKind {
    const val ACCESSIBILITY = 1 shl 0
    const val APP_DETAILS = 1 shl 1
    const val ADMIN = 1 shl 2
    const val DEV = 1 shl 3
    const val USERS = 1 shl 4
    const val VPN = 1 shl 5
    const val NOTIFICATION_ACCESS = 1 shl 6
    const val AUTOSTART = 1 shl 7
    const val UNINSTALL = 1 shl 8

    private val APP_DETAILS_NAMES = listOf(
        "installedappdetails", "appinfodashboard", "applicationsdetailsactivity", "appinfo", "appdetail",
    )
    private val USERS_NAMES = listOf("usersettings", "secondspace", "spaceindex")

    /** Mira el nombre de la clase de la ventana. Sin reservar memoria. */
    fun of(cls: CharSequence?): Int {
        if (cls == null || cls.isEmpty()) return 0
        var k = 0
        if (Labels.containsIc(cls, "accessibility")) k = k or ACCESSIBILITY
        for (n in APP_DETAILS_NAMES) if (Labels.containsIc(cls, n)) {
            k = k or APP_DETAILS
            break
        }
        if (Labels.containsIc(cls, "deviceadmin")) k = k or ADMIN
        if (Labels.containsIc(cls, "development")) k = k or DEV
        for (n in USERS_NAMES) if (Labels.containsIc(cls, n)) {
            k = k or USERS
            break
        }
        if (Labels.containsIc(cls, "vpn")) k = k or VPN
        if (Labels.containsIc(cls, "notificationaccess") || Labels.containsIc(cls, "notificationlistener")) {
            k = k or NOTIFICATION_ACCESS
        }
        if (Labels.containsIc(cls, "autostart")) k = k or AUTOSTART
        if (Labels.containsIc(cls, "uninstall")) k = k or UNINSTALL
        return k
    }

    /**
     * Cuadros de diálogo, menús y vistas genéricas: abren otra ventana sin que se haya salido de la
     * pantalla de debajo, así que no deben borrar lo recordado de ella.
     */
    fun isTransient(cls: CharSequence?): Boolean {
        if (cls == null) return true
        val s = cls.toString()
        return s.startsWith("android.widget.") || s.startsWith("android.view.") ||
            s.startsWith("androidx.") || Labels.containsIc(s, "dialog") || Labels.containsIc(s, "popup") ||
            Labels.containsIc(s, "menu") || Labels.containsIc(s, "toast")
    }
}

/** Un lector de textos de recursos de otra app (Ajustes, la app de Seguridad...). null si no hay. */
fun interface ResLookup {
    fun string(pkg: String, name: String): String?
}

/**
 * Las palabras que el guardián busca en pantalla, por idioma. Sin Android: la construcción es
 * pura (el lector de recursos del sistema se inyecta), así que se prueba con JUnit.
 *
 * Por qué hace falta: la protección dependía de que «Forzar detención» o «Accesibilidad» se
 * reconocieran por su texto, y con el teléfono en francés o en chino no se reconocía ninguna.
 * Hay tres fuentes, de más a menos fiable: lo que lee de los recursos de los propios Ajustes en el
 * idioma actual, la tabla incorporada de abajo, y las señales que no son texto (id de la vista,
 * nombre de la clase de la ventana; ver [WinKind] y [isDangerId]). Si el idioma no está en la
 * tabla y los Ajustes no dieron «forzar detención», [known] es false y el guardián pasa a modo
 * estricto: cierra todo lo que nombre a la app.
 */
class Labels private constructor(
    val matcher: Matcher,
    /** Hay traducción incorporada, o se leyó «Forzar detención» de los Ajustes. */
    val known: Boolean,
    private val usersTitles: Set<String>,
) {
    fun mask(text: CharSequence?): Int = matcher.scan(text)

    /** El título de la ventana es, tal cual, «Usuarios» (o «Varios usuarios»): la pantalla de usuarios. */
    fun isUsersTitle(title: CharSequence?): Boolean {
        if (title == null || title.isEmpty() || usersTitles.isEmpty()) return false
        return Fold.normalize(title) in usersTitles
    }

    companion object {
        /** Idiomas con traducción incorporada, además de es/en que siempre se cargan. */
        val BUILTIN_LANGUAGES: Set<String> get() = BUILTIN.keys

        /** El bloque de texto de un idioma (para los tests de cobertura). */
        internal fun builtinBlock(key: String): String? = BUILTIN[key]

        /** Los recursos del sistema que se intentan leer: (paquete, nombre, concepto). Un fallo no importa. */
        private val SETTINGS = "com.android.settings"
        private val RUNTIME: List<Triple<String, String, Int>> = listOf(
            Triple(SETTINGS, "force_stop", Concept.FORCE_STOP),
            Triple(SETTINGS, "force_stop_dlg_title", Concept.FORCE_STOP),
            Triple(SETTINGS, "uninstall_text", Concept.UNINSTALL),
            Triple(SETTINGS, "clear_user_data_text", Concept.CLEAR_DATA),
            Triple(SETTINGS, "storage_clear_user_data_text", Concept.CLEAR_DATA),
            Triple(SETTINGS, "clear_data_dlg_title", Concept.CLEAR_DATA),
            Triple(SETTINGS, "accessibility_settings", Concept.ACCESSIBILITY),
            Triple(SETTINGS, "accessibility_settings_title", Concept.ACCESSIBILITY),
            Triple(SETTINGS, "remove_device_admin", Concept.DEACTIVATE_ADMIN),
            Triple(SETTINGS, "vpn_disconnect", Concept.VPN_DISCONNECT_FORGET),
            Triple(SETTINGS, "vpn_forget", Concept.VPN_DISCONNECT_FORGET),
            Triple(SETTINGS, "private_dns_mode_provider", Concept.PRIVATE_DNS_EDITOR),
            Triple(SETTINGS, "private_dns_mode_provider_hostname_hint", Concept.PRIVATE_DNS_EDITOR),
            Triple(SETTINGS, "development_settings_title", Concept.DEVELOPER_OPTIONS),
            Triple(SETTINGS, "build_number", Concept.BUILD_NUMBER),
            Triple(SETTINGS, "proxy_hostname_label", Concept.PROXY_EDITOR),
            Triple(SETTINGS, "user_add_user_menu", Concept.USERS_SECOND_SPACE),
            Triple(SETTINGS, "user_add_user_or_profile_menu", Concept.USERS_SECOND_SPACE),
            Triple(SETTINGS, "user_add_user_title", Concept.USERS_SECOND_SPACE),
            Triple(SETTINGS, "user_add_guest_menu", Concept.USERS_SECOND_SPACE),
            Triple(SETTINGS, "background_activity_title", Concept.RESTRICT_BACKGROUND),
            Triple(SETTINGS, "restricted_true_label", Concept.RESTRICT_BACKGROUND),
            Triple("com.miui.securitycenter", "force_stop", Concept.FORCE_STOP),
            Triple("com.miui.securitycenter", "am_detail_force_stop", Concept.FORCE_STOP),
            Triple("com.miui.securitycenter", "uninstall", Concept.UNINSTALL),
            Triple("com.miui.securitycenter", "am_detail_uninstall", Concept.UNINSTALL),
            Triple("com.miui.securitycenter", "clear_data", Concept.CLEAR_DATA),
            Triple("com.miui.securitycenter", "am_detail_clear_data", Concept.CLEAR_DATA),
            Triple("com.miui.securitycenter", "autostart_title", Concept.AUTOSTART),
            Triple("com.android.vpndialogs", "disconnect", Concept.VPN_DISCONNECT_FORGET),
            Triple("com.android.vpndialogs", "disconnect_vpn", Concept.VPN_DISCONNECT_FORGET),
            Triple("com.miui.powerkeeper", "restrict_background", Concept.RESTRICT_BACKGROUND),
            Triple("com.miui.powerkeeper", "background_restrict", Concept.RESTRICT_BACKGROUND),
        )

        /** Recursos cuyo texto es el título exacto de la pantalla de usuarios. */
        private val RUNTIME_USERS_TITLES = listOf(SETTINGS to "user_settings_title", SETTINGS to "user_and_account_settings_title_users")

        /**
         * Sin traducción incorporada y sin «forzar detención» leído de los Ajustes, el guardián no
         * puede fiarse de las palabras y pasa a modo estricto.
         */
        fun decideKnown(hasBuiltin: Boolean, runtimeForceStop: Boolean): Boolean = hasBuiltin || runtimeForceStop

        /**
         * Las claves de idioma que se cargan para una configuración regional. «zh» sin escritura
         * ni país se carga en las dos variantes. Siempre se añaden es y en: es el idioma de quien
         * usa la app, y las apps del fabricante mezclan inglés en cualquier idioma.
         */
        fun languageKeys(language: String, script: String = "", country: String = ""): List<String> {
            val lang = when (language.lowercase(Locale.ROOT)) {
                "iw" -> "he"
                "in" -> "id"
                "no", "nb", "nn" -> "no"
                else -> language.lowercase(Locale.ROOT)
            }
            val keys = LinkedHashSet<String>()
            if (lang == "zh") {
                val hant = script.equals("Hant", true) || country.uppercase(Locale.ROOT) in setOf("TW", "HK", "MO")
                val hans = script.equals("Hans", true) || country.uppercase(Locale.ROOT) in setOf("CN", "SG")
                if (hant || !hans) keys += "zh-Hant"
                if (hans || !hant) keys += "zh-Hans"
            } else if (lang.isNotEmpty()) {
                keys += lang
            }
            keys += "es"
            keys += "en"
            return keys.toList()
        }

        /** ¿Hay traducción incorporada para el idioma (más allá de es/en que siempre están)? */
        fun hasBuiltin(language: String, script: String = "", country: String = ""): Boolean {
            // La primera clave es el propio idioma (es/en sólo se añaden detrás, siempre).
            return languageKeys(language, script, country).first() in BUILTIN
        }

        /**
         * Construye las etiquetas de un idioma. [lookup] lee los recursos del sistema (null en tests o
         * si no se puede); [appLabel] es el nombre de la app en este idioma.
         */
        fun build(
            language: String,
            script: String = "",
            country: String = "",
            lookup: ResLookup? = null,
            appLabel: String? = null,
        ): Labels {
            val patterns = ArrayList<Pair<String, Int>>()
            val titles = HashSet<String>()
            for (key in languageKeys(language, script, country)) {
                BUILTIN[key]?.let { parse(it, patterns, titles) }
            }
            patterns += "secretsavior" to Concept.OURS
            patterns += "com.secretsavior" to Concept.OURS
            if (!appLabel.isNullOrBlank()) patterns += appLabel to Concept.OURS
            patterns += "vpn" to Concept.VPN
            var runtimeForceStop = false
            if (lookup != null) {
                for ((pkg, name, concept) in RUNTIME) {
                    val s = try {
                        lookup.string(pkg, name)
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    if (!usableRuntime(s)) continue
                    patterns += s to concept
                    if (concept == Concept.FORCE_STOP) runtimeForceStop = true
                }
                for ((pkg, name) in RUNTIME_USERS_TITLES) {
                    val s = try {
                        lookup.string(pkg, name)
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    if (usableRuntime(s)) titles += Fold.normalize(s)
                }
            }
            val known = decideKnown(hasBuiltin(language, script, country), runtimeForceStop)
            return Labels(Matcher(patterns), known, titles)
        }

        /** Un texto leído del sistema sirve de patrón si no es una sigla suelta ni lleva marcadores. */
        fun usableRuntime(s: String): Boolean {
            if (s.contains('%') || s.contains('{')) return false
            val f = Fold.normalize(s)
            if (f.isEmpty()) return false
            return if (f.all { it.code < 128 }) f.length >= 4 else f.length >= 2
        }

        /**
         * Un bloque de idioma: líneas «CONCEPTO: frase | frase | ~genérica». «UT» son los títulos
         * exactos de la pantalla de usuarios. Las frases con «~» son genéricas (ver [Concept.WEAK]).
         */
        fun parse(block: String, out: MutableList<Pair<String, Int>>, titles: MutableSet<String>) {
            for (raw in block.lineSequence()) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                val code = line.substring(0, colon).trim()
                val phrases = line.substring(colon + 1).split('|').map { it.trim() }.filter { it.isNotEmpty() }
                if (code == "UT") {
                    for (p in phrases) titles += Fold.normalize(p)
                    continue
                }
                val bit = CODES[code] ?: continue
                for (p in phrases) {
                    if (p.startsWith("~")) out += p.substring(1) to Concept.weak(bit) else out += p to bit
                }
            }
        }

        private val CODES = mapOf(
            "FS" to Concept.FORCE_STOP, "UN" to Concept.UNINSTALL, "CD" to Concept.CLEAR_DATA,
            "AC" to Concept.ACCESSIBILITY, "DA" to Concept.DEACTIVATE_ADMIN,
            "VD" to Concept.VPN_DISCONNECT_FORGET, "SS" to Concept.USERS_SECOND_SPACE,
            "DO" to Concept.DEVELOPER_OPTIONS, "BN" to Concept.BUILD_NUMBER,
            "DNS" to Concept.PRIVATE_DNS_EDITOR, "PX" to Concept.PROXY_EDITOR,
            "RB" to Concept.RESTRICT_BACKGROUND, "AS" to Concept.AUTOSTART, "LK" to Concept.LOCKDOWN_TOGGLE,
        )

        /** Fragmentos del id de una vista que sólo llevan los botones de parar, desinstalar o borrar datos. */
        private val DANGER_IDS = listOf(
            "force_stop", "forcestop", "force_close", "uninstall", "clear_data", "cleardata",
            "clear_storage", "clear_user_data",
        )

        /** El id de la vista (p. ej. «com.android.settings:id/force_stop_button») delata un botón peligroso. */
        fun isDangerId(id: String?): Boolean {
            if (id == null) return false
            for (n in DANGER_IDS) if (containsIc(id, n)) return true
            return false
        }

        /** [needle] (en minúsculas ASCII) aparece en [hay] sin distinguir mayúsculas. No reserva memoria. */
        fun containsIc(hay: CharSequence?, needle: String): Boolean {
            if (hay == null) return false
            val n = needle.length
            var i = 0
            val last = hay.length - n
            while (i <= last) {
                var j = 0
                while (j < n && Character.toLowerCase(hay[i + j]) == needle[j]) j++
                if (j == n) return true
                i++
            }
            return false
        }

        // ------------------------------------------------------------------------------
        // Tabla incorporada. Frases tal como las muestran Android y las capas de los
        // fabricantes (MIUI/HyperOS, One UI). Preferir frases precisas; «~» = genérica.
        // ------------------------------------------------------------------------------
        private val BUILTIN: Map<String, String> = mapOf(
            "es" to """
                FS: forzar detención | forzar parada | forzar cierre | ~detener
                UN: desinstalar | ~eliminar | ~quitar
                CD: borrar datos | borrar almacenamiento | borrar el almacenamiento | borrar espacio | eliminar datos | vaciar almacenamiento | ~borrar
                AC: accesibilidad
                DA: desactivar esta aplicación de administración | desactivar esta app de administración | desactivar administrador | desactivar
                VD: desconectar | olvidar | desconexión
                SS: segundo espacio | añadir invitado | agregar invitado | añadir usuario | agregar usuario | varios usuarios | múltiples usuarios
                DO: opciones de desarrollador | opciones para desarrolladores
                BN: número de compilación | número de versión | versión de miui | versión de hyperos | versión del os
                DNS: nombre de host del proveedor de dns | proveedor de dns privado | nombre de host del proveedor
                PX: nombre de host del proxy | nombre del host proxy
                RB: restringir actividad en segundo plano | restricción en segundo plano | restricciones en segundo plano | restringir la actividad en segundo plano
                AS: autoencendido | autoinicio | inicio automático | arranque automático | autostart
                LK: bloquear conexiones sin vpn
                UT: usuarios | varios usuarios | múltiples usuarios
            """,
            "en" to """
                FS: force stop | force close | force-stop
                UN: uninstall | ~remove | ~delete
                CD: clear data | clear storage | clear app data | clear all data | delete data | erase data | ~clear
                AC: accessibility
                DA: deactivate this device admin app | deactivate device admin | remove device admin | deactivate
                VD: disconnect | forget vpn | forget
                SS: second space | add guest | add user | multiple users
                DO: developer options
                BN: build number | miui version | hyperos version | os version | version of miui | version of hyperos
                DNS: provider hostname | hostname of dns provider | dns provider hostname
                PX: proxy hostname | proxy host name
                RB: restrict background | background restriction | background activity
                AS: autostart | auto-start | auto start
                LK: block connections without vpn
                UT: users | multiple users
            """,
            "pt" to """
                FS: forçar parada | forçar paragem | forçar encerramento | parar forçosamente | forçar a parada | ~parar
                UN: desinstalar | ~remover | ~excluir
                CD: limpar dados | limpar armazenamento | apagar dados | limpar os dados | ~limpar | ~apagar
                AC: acessibilidade
                DA: desativar este app de administração | desativar administrador | desativar | desactivar
                VD: desconectar | desligar vpn | esquecer
                SS: segundo espaço | adicionar convidado | adicionar usuário | adicionar utilizador | vários usuários | vários utilizadores | múltiplos usuários
                DO: opções do desenvolvedor | opções de programador | opções para programadores | opções de desenvolvedor
                BN: número da versão | número de compilação | número da compilação | versão do miui | versão do hyperos | versão do os
                DNS: nome do host do provedor de dns | nome de host do fornecedor de dns | nome do host do fornecedor
                PX: nome do host do proxy | nome de host do proxy | hostname do proxy
                RB: restringir atividade em segundo plano | restringir a atividade em segundo plano | restrição em segundo plano | restrições em segundo plano
                AS: início automático | inicialização automática | autoinício | autostart
                LK: bloquear conexões sem vpn | bloquear ligações sem vpn
                UT: usuários | utilizadores | vários usuários | vários utilizadores
            """,
            "fr" to """
                FS: forcer l'arrêt | forcer arrêt | arrêt forcé | ~arrêter
                UN: désinstaller | ~supprimer
                CD: effacer les données | supprimer les données | vider les données | effacer le stockage | vider le stockage | effacer données | ~effacer | ~vider
                AC: accessibilité
                DA: désactiver cette application d'administration | désactiver l'administrateur | désactiver
                VD: déconnecter | oublier | déconnexion
                SS: second espace | deuxième espace | ajouter un invité | ajouter un utilisateur | plusieurs utilisateurs | ajouter invité
                DO: options pour les développeurs | options de développement | options développeur | options pour développeurs
                BN: numéro de build | numéro de version | numéro de la version | version de miui | version de hyperos | version d'os
                DNS: nom d'hôte du fournisseur de dns | nom d'hôte du fournisseur dns privé
                PX: nom d'hôte du proxy | nom d'hôte proxy | nom hôte du proxy
                RB: restreindre l'activité en arrière-plan | restriction en arrière-plan | restrictions en arrière-plan | limiter l'activité en arrière-plan
                AS: démarrage automatique | lancement automatique | autodémarrage | autostart
                LK: bloquer les connexions sans vpn
                UT: utilisateurs | multi-utilisateurs | plusieurs utilisateurs
            """,
            "de" to """
                FS: beenden erzwingen | stoppen erzwingen | anhalten erzwingen | erzwungen beenden | ~beenden
                UN: deinstallieren | ~entfernen | ~löschen
                CD: daten löschen | speicher löschen | speicherplatz löschen | app-daten löschen | ~löschen
                AC: bedienungshilfen | barrierefreiheit
                DA: diese geräteadministrator-app deaktivieren | geräteadministrator deaktivieren | deaktivieren
                VD: trennen | vergessen | vpn trennen
                SS: zweiter bereich | zweiter space | second space | gast hinzufügen | nutzer hinzufügen | benutzer hinzufügen | mehrere nutzer | mehrere benutzer
                DO: entwickleroptionen
                BN: build-nummer | buildnummer | versionsnummer | miui-version | hyperos-version | os-version
                DNS: hostname des anbieters von privatem dns | hostname des dns-anbieters | hostname des anbieters
                PX: proxy-hostname | hostname des proxys
                RB: hintergrundaktivität einschränken | hintergrundbeschränkung | hintergrundnutzung einschränken
                AS: autostart | automatischer start
                LK: verbindungen ohne vpn blockieren
                UT: nutzer | benutzer | mehrere nutzer | mehrere benutzer
            """,
            "it" to """
                FS: forza arresto | forza interruzione | arresto forzato | interrompi forzatamente | forza chiusura | ~arresta
                UN: disinstalla | ~rimuovi | ~elimina
                CD: cancella dati | cancella spazio di archiviazione | cancella archiviazione | cancella i dati | svuota archivio | elimina dati | ~cancella
                AC: accessibilità
                DA: disattiva questa app di amministrazione | disattiva amministratore | disattiva
                VD: disconnetti | dimentica
                SS: secondo spazio | aggiungi ospite | aggiungi utente | più utenti | utenti multipli
                DO: opzioni sviluppatore | opzioni per gli sviluppatori
                BN: numero build | numero di build | versione miui | versione hyperos | versione os
                DNS: nome host del provider dns | nome host del provider
                PX: nome host proxy | nome host del proxy | hostname proxy
                RB: limita attività in background | limita l'attività in background | limitazione in background | restrizioni in background
                AS: avvio automatico | autostart
                LK: blocca connessioni senza vpn | blocca le connessioni senza vpn
                UT: utenti | utenti multipli
            """,
            "nl" to """
                FS: forceer stop | forceer stoppen | geforceerd stoppen | forceer afsluiten | afsluiten forceren | ~stoppen
                UN: deïnstalleren | de-installeren | ~verwijderen
                CD: gegevens wissen | opslag wissen | opslagruimte wissen | gegevens verwijderen | ~wissen
                AC: toegankelijkheid
                DA: deze apparaatbeheerder-app uitschakelen | apparaatbeheerder uitschakelen | deactiveren | uitschakelen
                VD: verbinding verbreken | vergeten
                SS: tweede ruimte | gast toevoegen | gebruiker toevoegen | meerdere gebruikers
                DO: ontwikkelaarsopties
                BN: buildnummer | miui-versie | hyperos-versie | os-versie
                DNS: hostnaam van provider van privé-dns | hostnaam van dns-provider | provider van privé-dns
                PX: proxyhostnaam | hostnaam van proxy
                RB: achtergrondactiviteit beperken | beperking op de achtergrond | achtergrondbeperking
                AS: automatisch starten | autostart
                LK: verbindingen zonder vpn blokkeren
                UT: gebruikers | meerdere gebruikers
            """,
            "pl" to """
                FS: wymuś zatrzymanie | wymuś zamknięcie | zatrzymaj siłą | wymuszone zatrzymanie | wymuś zakończenie | ~zatrzymaj
                UN: odinstaluj | ~usuń
                CD: wyczyść dane | wyczyść pamięć | usuń dane | wyczyść dane aplikacji | ~wyczyść
                AC: ułatwienia dostępu
                DA: dezaktywuj tę aplikację administratora urządzenia | dezaktywuj | wyłącz administratora
                VD: rozłącz | zapomnij | odłącz
                SS: drugie miejsce | druga przestrzeń | dodaj gościa | dodaj użytkownika | wielu użytkowników | wiele użytkowników | second space
                DO: opcje programisty | opcje deweloperskie | opcje dla programistów | opcje dla deweloperów
                BN: numer kompilacji | numer wersji | wersja miui | wersja hyperos | wersja os
                DNS: nazwa hosta dostawcy prywatnego dns | nazwa hosta dostawcy dns
                PX: nazwa hosta serwera proxy | nazwa hosta proxy
                RB: ogranicz aktywność w tle | ograniczenia w tle | ograniczenie aktywności w tle
                AS: autostart | autouruchamianie | automatyczne uruchamianie
                LK: blokuj połączenia bez vpn | blokuj połączenia bez sieci vpn
                UT: użytkownicy | wielu użytkowników
            """,
            "ru" to """
                FS: принудительно остановить | принудительная остановка | остановить принудительно | принудительно завершить | ~остановить
                UN: деинсталлировать | ~удалить | ~удаление
                CD: очистить данные | стереть данные | очистить хранилище | удалить данные | очистить память | ~очистить | ~стереть
                AC: специальные возможности | универсальный доступ
                DA: отключить это приложение администратора | отключить администратора | деактивировать | отключить
                VD: отключить vpn | отключиться | забыть
                SS: второе пространство | добавить гостя | добавить пользователя | несколько пользователей | second space
                DO: для разработчиков | параметры разработчика | режим разработчика
                BN: номер сборки | версия miui | версия hyperos | версия os | версия ос
                DNS: имя хоста поставщика частного dns | имя хоста dns-провайдера | имя хоста провайдера частного dns | имя хоста поставщика
                PX: имя хоста прокси | имя хоста прокси-сервера
                RB: ограничить фоновую активность | ограничения фоновой | фоновые ограничения | ограничение фоновой | ограничить фоновый режим
                AS: автозапуск | автоматический запуск
                LK: блокировать подключения без vpn | блокировать подключения без использования vpn
                UT: пользователи | несколько пользователей
            """,
            "uk" to """
                FS: примусово зупинити | примусова зупинка | зупинити примусово | ~зупинити
                UN: деінсталювати | ~видалити
                CD: очистити дані | стерти дані | очистити сховище | видалити дані | очистити пам'ять | ~очистити
                AC: спеціальні можливості | універсальний доступ
                DA: вимкнути цей додаток адміністратора пристрою | деактивувати | вимкнути
                VD: від'єднати | відключити | забути
                SS: другий простір | додати гостя | додати користувача | кілька користувачів
                DO: для розробників | параметри розробника
                BN: номер складання | номер збірки | версія miui | версія hyperos | версія os
                DNS: ім'я хоста постачальника приватного dns | ім'я хоста постачальника dns
                PX: ім'я хоста проксі | ім'я хоста проксі-сервера
                RB: обмежити фонову активність | обмеження фонової | фонові обмеження
                AS: автозапуск | автоматичний запуск
                LK: блокувати з'єднання без vpn | блокувати підключення без vpn
                UT: користувачі | кілька користувачів
            """,
            "tr" to """
                FS: durmaya zorla | zorla durdur | zorla dur | zorla kapat | zorla durdurma | ~durdur
                UN: yüklemeyi kaldır | uygulamayı kaldır | ~kaldır | ~sil
                CD: verileri temizle | depolamayı temizle | verileri sil | depolama alanını temizle | ~temizle
                AC: erişilebilirlik
                DA: bu cihaz yönetici uygulamasını devre dışı bırak | yöneticiyi devre dışı bırak | devre dışı bırak
                VD: bağlantıyı kes | unut
                SS: ikinci alan | ikinci uzay | misafir ekle | kullanıcı ekle | birden fazla kullanıcı | çoklu kullanıcı
                DO: geliştirici seçenekleri
                BN: derleme numarası | yapı numarası | miui sürümü | hyperos sürümü | os sürümü | sürüm numarası
                DNS: özel dns sağlayıcısının ana makine adı | dns sağlayıcısı ana makine adı
                PX: proxy ana makine adı | proxy ana bilgisayar adı
                RB: arka plan etkinliğini kısıtla | arka plan kısıtlaması | arka plan kısıtlamaları | arka planda kısıtla
                AS: otomatik başlat | otomatik başlatma | autostart
                LK: vpn olmadan bağlantıları engelle | vpn olmayan bağlantıları engelle
                UT: kullanıcılar | birden fazla kullanıcı
            """,
            "ro" to """
                FS: oprire forțată | forțați oprirea | forțare oprire | opriți forțat | oprire fortata | ~opriți
                UN: dezinstalați | dezinstalare | dezinstalează | ~eliminați | ~ștergeți
                CD: ștergeți datele | șterge datele | ștergeți spațiul de stocare | goliți stocarea | șterge spațiul de stocare | ~ștergeți | ~șterge
                AC: accesibilitate
                DA: dezactivați această aplicație de administrare | dezactivați administratorul | dezactivați | dezactivează
                VD: deconectați | deconectare | uitați | deconectează
                SS: al doilea spațiu | adăugați invitat | adăugați utilizator | mai mulți utilizatori | utilizatori multipli
                DO: opțiuni pentru dezvoltatori | opțiuni dezvoltator
                BN: număr versiune | număr build | numărul versiunii | versiunea miui | versiunea hyperos | versiune os
                DNS: numele gazdei furnizorului dns privat | numele de gazdă al furnizorului dns
                PX: numele gazdei proxy | nume de gazdă proxy
                RB: restricționați activitatea în fundal | restricție în fundal | restricții în fundal
                AS: pornire automată | autostart | lansare automată
                LK: blocați conexiunile fără vpn | blocare conexiuni fără vpn
                UT: utilizatori | mai mulți utilizatori
            """,
            "cs" to """
                FS: vynutit zastavení | vynutit ukončení | násilně ukončit | ~zastavit
                UN: odinstalovat | ~odstranit
                CD: vymazat data | vymazat úložiště | smazat data | vymazat paměť | ~vymazat | ~smazat
                AC: přístupnost | usnadnění
                DA: deaktivovat tuto aplikaci správce zařízení | deaktivovat | vypnout správce
                VD: odpojit | zapomenout
                SS: druhý prostor | přidat hosta | přidat uživatele | více uživatelů
                DO: možnosti pro vývojáře | vývojářské možnosti | pro vývojáře
                BN: číslo sestavení | číslo verze | verze miui | verze hyperos | verze os
                DNS: název hostitele poskytovatele soukromého dns | název hostitele poskytovatele dns
                PX: název hostitele proxy | název proxy hostitele
                RB: omezit aktivitu na pozadí | omezení na pozadí | omezení aktivity na pozadí
                AS: automatické spuštění | autostart | automatický start
                LK: blokovat připojení bez vpn
                UT: uživatelé | více uživatelů
            """,
            "hu" to """
                FS: kényszerített leállítás | leállítás kényszerítése | kényszerített bezárás | erőltetett leállítás
                UN: eltávolítás | telepítés eltávolítása | ~törlés
                CD: adatok törlése | tárhely törlése | tárhely ürítése | ~törlése
                AC: kisegítő lehetőségek | hozzáférhetőség
                DA: eszközrendszergazdai alkalmazás kikapcsolása | rendszergazda kikapcsolása | inaktiválás | kikapcsolás
                VD: leválasztás | kapcsolat bontása | elfelejtés | elfelejt
                SS: második tér | vendég hozzáadása | felhasználó hozzáadása | több felhasználó | második hely
                DO: fejlesztői beállítások | fejlesztői lehetőségek
                BN: build-szám | buildszám | verziószám | miui-verzió | hyperos-verzió | os-verzió
                DNS: magánjellegű dns-szolgáltató gazdagépneve | dns-szolgáltató gazdagépneve | szolgáltató gazdagépneve
                PX: proxy gazdagépneve | proxy állomásneve | proxy gazdagép
                RB: háttértevékenység korlátozása | háttérkorlátozás | háttérben futás korlátozása
                AS: automatikus indítás | autostart | önindítás
                LK: vpn nélküli kapcsolatok letiltása | vpn nélküli kapcsolatok blokkolása
                UT: felhasználók | több felhasználó
            """,
            "el" to """
                FS: αναγκαστική διακοπή | αναγκαστικός τερματισμός | αναγκαστικό κλείσιμο | εξαναγκαστική διακοπή | αναγκαστική παύση
                UN: κατάργηση εγκατάστασης | απεγκατάσταση | ~διαγραφή | ~κατάργηση
                CD: διαγραφή δεδομένων | εκκαθάριση αποθηκευτικού χώρου | εκκαθάριση δεδομένων | διαγραφή αποθηκευτικού χώρου | ~εκκαθάριση | ~διαγραφή
                AC: προσβασιμότητα
                DA: απενεργοποίηση αυτής της εφαρμογής διαχειριστή | απενεργοποίηση διαχειριστή | απενεργοποίηση | απενεργοποιήστε
                VD: αποσύνδεση | ξεχάσετε | ξέχασε
                SS: δεύτερος χώρος | προσθήκη επισκέπτη | προσθήκη χρήστη | πολλαπλοί χρήστες | πολλοί χρήστες
                DO: επιλογές προγραμματιστή | επιλογές για προγραμματιστές
                BN: αριθμός έκδοσης | αριθμός build | έκδοση miui | έκδοση hyperos | έκδοση os
                DNS: όνομα κεντρικού υπολογιστή παρόχου ιδιωτικού dns | όνομα κεντρικού υπολογιστή παρόχου dns
                PX: όνομα κεντρικού υπολογιστή διακομιστή μεσολάβησης | όνομα κεντρικού υπολογιστή proxy | όνομα κεντρικού υπολογιστή διακομιστή proxy
                RB: περιορισμός δραστηριότητας παρασκηνίου | περιορισμός παρασκηνίου | περιορισμοί παρασκηνίου
                AS: αυτόματη εκκίνηση | αυτόματη έναρξη | autostart
                LK: αποκλεισμός συνδέσεων χωρίς vpn
                UT: χρήστες | πολλοί χρήστες
            """,
            "ar" to """
                FS: فرض الإيقاف | إيقاف إجباري | فرض إيقاف | إيقاف بالقوة | إيقاف قسري
                UN: إلغاء التثبيت | إزالة التثبيت | ~إزالة | ~حذف
                CD: محو البيانات | مسح البيانات | مسح مساحة التخزين | محو مساحة التخزين | حذف البيانات | ~مسح | ~محو
                AC: إمكانية الوصول | سهولة الاستخدام
                DA: إيقاف تفعيل تطبيق مشرف الجهاز هذا | إلغاء تنشيط | إلغاء تفعيل | إيقاف تفعيل
                VD: قطع الاتصال | نسيان | إلغاء الاتصال | فصل
                SS: المساحة الثانية | إضافة ضيف | إضافة مستخدم | عدة مستخدمين | مستخدمون متعددون
                DO: خيارات المطورين | خيارات المطوّر | خيارات المطور
                BN: رقم الإصدار | رقم الإنشاء | رقم البناء | إصدار miui | إصدار hyperos
                DNS: اسم مضيف موفر نظام أسماء النطاقات الخاص | اسم مضيف موفر dns | اسم مضيف مزود dns الخاص | اسم مضيف مزوّد dns
                PX: اسم مضيف الخادم الوكيل | اسم مضيف الوكيل | اسم مضيف بروكسي
                RB: تقييد النشاط في الخلفية | تقييد الخلفية | قيود الخلفية | تقييد الأنشطة في الخلفية
                AS: التشغيل التلقائي | بدء تلقائي | autostart
                LK: حظر الاتصالات بدون vpn | حظر الاتصالات من دون vpn
                UT: المستخدمون | مستخدمون متعددون
            """,
            "he" to """
                FS: אילוץ עצירה | עצירה בכוח | כפה עצירה | הפסקה בכוח | אלץ עצירה
                UN: הסר התקנה | הסרת התקנה | הסרה | ~מחק
                CD: ניקוי נתונים | מחיקת נתונים | נקה נתונים | נקה אחסון | ניקוי אחסון | ~נקה | ~מחק
                AC: נגישות
                DA: השבת את אפליקציית מנהל המכשיר | השבתת מנהל | השבת | בטל הפעלה
                VD: נתק | נתקו | שכח | התנתק | ניתוק
                SS: מרחב שני | הוסף אורח | הוסף משתמש | משתמשים מרובים | הוספת אורח | הוספת משתמש
                DO: אפשרויות פיתוח | אפשרויות למפתחים | אפשרויות מפתח
                BN: מספר גרסה | מספר בנייה | גרסת miui | גרסת hyperos
                DNS: שם המארח של ספק dns פרטי | שם מארח של ספק dns | שם המארח של ספק
                PX: שם מארח של שרת proxy | שם המארח של ה-proxy | שם מארח של proxy | שם מארח של פרוקסי
                RB: הגבלת פעילות ברקע | הגבלות ברקע | הגבלת רקע
                AS: הפעלה אוטומטית | autostart
                LK: חסימת חיבורים ללא vpn | חסום חיבורים ללא vpn
                UT: משתמשים | משתמשים מרובים
            """,
            "fa" to """
                FS: توقف اجباری | اجبار به توقف | متوقف کردن اجباری | توقف اجباری
                UN: حذف نصب | لغو نصب | نصب‌زدایی | ~حذف
                CD: پاک کردن داده‌ها | پاک کردن داده | پاک کردن فضای ذخیره‌سازی | پاک کردن فضای ذخیره | ~پاک کردن
                AC: دسترسی‌پذیری | دسترس‌پذیری | دسترسی پذیری
                DA: غیرفعال کردن این برنامه سرپرست دستگاه | غیرفعال کردن | غیرفعال‌سازی
                VD: قطع اتصال | فراموش کردن | فراموشی | قطع
                SS: فضای دوم | افزودن مهمان | افزودن کاربر | چند کاربر | چندکاربره
                DO: گزینه‌های برنامه‌نویس | گزینه‌های توسعه‌دهنده | گزینه های توسعه دهنده
                BN: شماره ساخت | شماره نسخه | نسخه miui | نسخه hyperos
                DNS: نام میزبان ارائه‌دهنده dns خصوصی | نام میزبان ارائه دهنده dns | نام میزبان ارائه‌دهنده
                PX: نام میزبان پروکسی | نام میزبان پراکسی
                RB: محدود کردن فعالیت در پس‌زمینه | محدودیت پس‌زمینه | محدودیت‌های پس‌زمینه
                AS: راه‌اندازی خودکار | شروع خودکار | اجرای خودکار | autostart
                LK: مسدود کردن اتصال‌های بدون vpn | مسدود کردن اتصالات بدون vpn
                UT: کاربران | چند کاربر
            """,
            "hi" to """
                FS: ज़बरदस्ती रोकें | जबरदस्ती रोकें | ज़बरदस्ती बंद करें | फ़ोर्स स्टॉप | फोर्स स्टॉप | बलपूर्वक रोकें | ~रोकें
                UN: अनइंस्टॉल करें | अनइंस्टॉल | ~हटाएं
                CD: डेटा साफ़ करें | डेटा साफ करें | स्टोरेज साफ़ करें | डेटा मिटाएं | स्टोरेज खाली करें | ~साफ़
                AC: सुलभता
                DA: इस डिवाइस एडमिन ऐप्लिकेशन को निष्क्रिय करें | निष्क्रिय करें | बंद करें
                VD: डिसकनेक्ट | कनेक्शन तोड़ें | भूल जाएं
                SS: दूसरा स्पेस | अतिथि जोड़ें | उपयोगकर्ता जोड़ें | एकाधिक उपयोगकर्ता | कई उपयोगकर्ता | second space
                DO: डेवलपर विकल्प | डेवलपर के लिए विकल्प
                BN: बिल्ड नंबर | बिल्ड संख्या | संस्करण संख्या | miui संस्करण | hyperos संस्करण
                DNS: निजी dns प्रदाता का होस्टनाम | dns प्रदाता का होस्टनाम | निजी dns प्रदाता होस्टनाम
                PX: प्रॉक्सी होस्टनाम | प्रॉक्सी का होस्टनाम | प्रॉक्सी होस्ट नाम
                RB: बैकग्राउंड गतिविधि को प्रतिबंधित करें | बैकग्राउंड प्रतिबंध | पृष्ठभूमि गतिविधि प्रतिबंधित करें
                AS: ऑटो-स्टार्ट | ऑटोस्टार्ट | ऑटो स्टार्ट | स्वतः प्रारंभ
                LK: vpn के बिना कनेक्शन ब्लॉक करें | vpn के बिना कनेक्शन को ब्लॉक करें
                UT: उपयोगकर्ता | एकाधिक उपयोगकर्ता
            """,
            "id" to """
                FS: paksa berhenti | paksa hentikan | hentikan paksa | paksa tutup
                UN: copot pemasangan | hapus instalasi | uninstal | ~hapus | ~copot
                CD: hapus data | hapus penyimpanan | hapus semua data | bersihkan data | kosongkan penyimpanan | ~hapus | ~bersihkan
                AC: aksesibilitas
                DA: nonaktifkan aplikasi admin perangkat ini | nonaktifkan admin | nonaktifkan
                VD: putuskan sambungan | lupakan | lupakan vpn
                SS: ruang kedua | tambahkan tamu | tambahkan pengguna | tambah tamu | tambah pengguna | beberapa pengguna | banyak pengguna
                DO: opsi developer | opsi pengembang
                BN: nomor build | nomor versi | versi miui | versi hyperos | versi os
                DNS: nama host penyedia dns pribadi | nama host penyedia dns
                PX: nama host proxy | hostname proxy
                RB: batasi aktivitas latar belakang | pembatasan latar belakang | batasan latar belakang
                AS: mulai otomatis | autostart
                LK: blokir koneksi tanpa vpn
                UT: pengguna | beberapa pengguna
            """,
            "ms" to """
                FS: paksa henti | henti paksa | paksa berhenti
                UN: nyahpasang | ~alih keluar | ~padam
                CD: kosongkan data | kosongkan storan | padam data | ~kosongkan | ~padam
                AC: kebolehcapaian | aksesibiliti
                DA: nyahaktifkan apl pentadbir peranti ini | nyahaktifkan pentadbir | nyahaktifkan
                VD: putuskan sambungan | lupakan | lupa vpn
                SS: ruang kedua | tambah tetamu | tambah pengguna | berbilang pengguna | pelbagai pengguna
                DO: pilihan pembangun
                BN: nombor binaan | nombor versi | versi miui | versi hyperos | versi os
                DNS: nama hos pembekal dns peribadi | nama hos pembekal dns
                PX: nama hos proksi | nama hos proxy
                RB: hadkan aktiviti latar belakang | sekatan latar belakang | had latar belakang
                AS: mula auto | mula automatik | autostart | permulaan automatik
                LK: sekat sambungan tanpa vpn
                UT: pengguna | berbilang pengguna
            """,
            "vi" to """
                FS: buộc dừng | dừng buộc | buộc đóng | ép dừng | buộc ngừng
                UN: gỡ cài đặt | ~gỡ | ~xóa
                CD: xóa dữ liệu | xóa bộ nhớ | xóa dung lượng | xoá dữ liệu | xoá bộ nhớ | ~xóa | ~xoá
                AC: hỗ trợ tiếp cận | trợ năng
                DA: hủy kích hoạt ứng dụng quản trị thiết bị này | vô hiệu hóa quản trị | hủy kích hoạt | vô hiệu hóa
                VD: ngắt kết nối | quên | quên vpn
                SS: không gian thứ hai | thêm khách | thêm người dùng | nhiều người dùng
                DO: tùy chọn nhà phát triển | tuỳ chọn nhà phát triển | tùy chọn cho nhà phát triển
                BN: số bản dựng | số hiệu bản dựng | số bản xây dựng | số phiên bản | phiên bản miui | phiên bản hyperos | phiên bản os
                DNS: tên máy chủ của nhà cung cấp dns riêng tư | tên máy chủ nhà cung cấp dns
                PX: tên máy chủ proxy | tên máy chủ của proxy | tên máy chủ lưu trữ proxy
                RB: hạn chế hoạt động trong nền | hạn chế nền | giới hạn hoạt động nền | hạn chế hoạt động nền
                AS: tự động khởi động | tự khởi động | autostart | khởi chạy tự động
                LK: chặn các kết nối không dùng vpn | chặn kết nối không có vpn
                UT: người dùng | nhiều người dùng
            """,
            "th" to """
                FS: บังคับหยุด | บังคับให้หยุด | บังคับปิด
                UN: ถอนการติดตั้ง | ถอนติดตั้ง | ~ลบ
                CD: ล้างข้อมูล | ล้างพื้นที่เก็บข้อมูล | ลบข้อมูล | ~ล้าง
                AC: การช่วยการเข้าถึง | การช่วยเหลือพิเศษ | การเข้าถึงสำหรับผู้พิการ | ความสามารถพิเศษ
                DA: ปิดใช้งานแอปผู้ดูแลระบบอุปกรณ์นี้ | ปิดใช้งานผู้ดูแลระบบ | ปิดใช้งาน | ยกเลิกการเปิดใช้งาน
                VD: ยกเลิกการเชื่อมต่อ | ตัดการเชื่อมต่อ | ลืม vpn | ลืม
                SS: พื้นที่ที่สอง | พื้นที่ที่ 2 | เพิ่มผู้เยี่ยมชม | เพิ่มแขก | เพิ่มผู้ใช้ | ผู้ใช้หลายคน
                DO: ตัวเลือกสำหรับนักพัฒนาซอฟต์แวร์ | ตัวเลือกนักพัฒนา | ตัวเลือกสำหรับนักพัฒนา
                BN: หมายเลขบิลด์ | หมายเลขรุ่น | เวอร์ชัน miui | เวอร์ชัน hyperos | เวอร์ชัน os
                DNS: ชื่อโฮสต์ของผู้ให้บริการ dns ส่วนตัว | ชื่อโฮสต์ผู้ให้บริการ dns
                PX: ชื่อโฮสต์พร็อกซี | ชื่อโฮสต์ของพร็อกซี
                RB: จำกัดกิจกรรมในพื้นหลัง | การจำกัดพื้นหลัง | ข้อจำกัดในพื้นหลัง
                AS: เริ่มอัตโนมัติ | เริ่มต้นอัตโนมัติ | autostart
                LK: บล็อกการเชื่อมต่อที่ไม่ใช้ vpn | บล็อกการเชื่อมต่อที่ไม่มี vpn
                UT: ผู้ใช้ | ผู้ใช้หลายคน
            """,
            "zh-Hans" to """
                FS: 强行停止 | 强制停止 | 强制结束 | 强行结束 | 强行关闭 | ~停止
                UN: 卸载 | ~删除 | ~移除
                CD: 清除数据 | 清除存储空间 | 清空数据 | 清除存储 | 清除全部数据 | ~清除 | ~清空
                AC: 无障碍 | 辅助功能 | 协助工具
                DA: 停用此设备管理应用 | 停用设备管理员 | 停用此设备管理员应用 | 停用 | 取消激活
                VD: 断开连接 | 断开 | 忘记 | 忘记vpn
                SS: 第二空间 | 添加访客 | 添加用户 | 多用户 | 多个用户
                DO: 开发者选项 | 开发人员选项 | 开发者模式
                BN: 版本号 | 内部版本号 | miui 版本 | hyperos 版本 | os 版本 | 系统版本
                DNS: 专用dns提供商主机名 | 私人dns提供商主机名 | dns提供商主机名 | 专用dns提供者主机名
                PX: 代理主机名 | 代理服务器主机名
                RB: 限制后台活动 | 后台限制 | 后台活动限制 | 限制后台
                AS: 自启动 | 自动启动 | autostart | 应用自启动
                LK: 屏蔽没有vpn的连接 | 阻止没有vpn的连接 | 禁止没有vpn的连接
                UT: 用户 | 多用户
            """,
            "zh-Hant" to """
                FS: 強制停止 | 強行停止 | 強制結束 | 強制關閉 | ~停止
                UN: 解除安裝 | 移除安裝 | 卸載 | ~移除 | ~刪除
                CD: 清除資料 | 清除儲存空間 | 清除儲存 | 清空資料 | ~清除 | ~清空
                AC: 無障礙 | 輔助使用 | 協助工具
                DA: 停用這個裝置管理應用程式 | 停用裝置管理員 | 停用 | 取消啟用
                VD: 中斷連線 | 斷線 | 忘記 | 忘記vpn | 中斷
                SS: 第二空間 | 新增訪客 | 新增使用者 | 多位使用者 | 多個使用者 | 多用戶 | 新增用戶
                DO: 開發人員選項 | 開發者選項
                BN: 版本號碼 | 版本號 | build 編號 | 版號 | miui 版本 | hyperos 版本 | os 版本 | 系統版本 | 組建編號 | 版本編號
                DNS: 私人dns供應商主機名稱 | dns供應商主機名稱 | 專用dns供應商主機名稱
                PX: proxy主機名稱 | 代理伺服器主機名稱 | 代理主機名稱
                RB: 限制背景活動 | 背景限制 | 背景活動限制 | 限制背景
                AS: 自動啟動 | 自啟動 | autostart | 自動啟動管理
                LK: 封鎖沒有vpn的連線 | 封鎖未使用vpn的連線
                UT: 使用者 | 用戶 | 多位使用者
            """,
            "ja" to """
                FS: 強制停止 | 強制終了 | 強制的に停止 | ~停止
                UN: アンインストール | ~削除
                CD: データを消去 | データを削除 | ストレージを消去 | ストレージを削除 | データを全て消去 | データ消去 | ~消去 | ~削除 | ~クリア
                AC: ユーザー補助 | アクセシビリティ | ユーザ補助
                DA: このデバイス管理アプリを無効にする | デバイス管理アプリを無効 | 無効にする | 無効化
                VD: 接続を解除 | 切断 | vpnを削除 | 削除
                SS: セカンドスペース | ゲストを追加 | ユーザーを追加 | 複数ユーザー | マルチユーザー
                DO: 開発者向けオプション | 開発者オプション
                BN: ビルド番号 | バージョン番号 | miuiバージョン | hyperosバージョン | osバージョン | システムバージョン
                DNS: プライベート dns プロバイダのホスト名 | dns プロバイダのホスト名 | プライベートdnsプロバイダーのホスト名
                PX: プロキシのホスト名 | プロキシ ホスト名 | プロキシホスト名
                RB: バックグラウンド アクティビティを制限 | バックグラウンドの制限 | バックグラウンドアクティビティを制限 | バックグラウンド制限
                AS: 自動起動 | 自動スタート | autostart | オートスタート
                LK: vpnなしの接続をブロック | vpnを使用しない接続をブロック
                UT: ユーザー | 複数ユーザー
            """,
            "ko" to """
                FS: 강제 중지 | 강제 종료 | 강제 정지 | ~중지
                UN: 앱 삭제 | 앱 제거 | ~삭제 | ~제거
                CD: 데이터 삭제 | 데이터 지우기 | 저장공간 지우기 | 저장소 지우기 | 저장공간 삭제 | ~지우기 | ~삭제
                AC: 접근성 | 손쉬운 사용
                DA: 이 기기 관리 앱 사용 중지 | 기기 관리자 비활성화 | 비활성화 | 사용 중지
                VD: 연결 해제 | 연결 끊기 | 잊기
                SS: 보조 공간 | 세컨드 스페이스 | 게스트 추가 | 사용자 추가 | 다중 사용자 | 여러 사용자 | second space
                DO: 개발자 옵션 | 개발자 설정 | 개발자 모드
                BN: 빌드 번호 | 버전 번호 | miui 버전 | hyperos 버전 | os 버전
                DNS: 비공개 dns 제공업체 호스트 이름 | dns 제공업체 호스트 이름 | 비공개 dns 공급자 호스트 이름 | dns 공급업체 호스트 이름
                PX: 프록시 호스트 이름 | 프록시 호스트명
                RB: 백그라운드 활동 제한 | 백그라운드 제한 | 백그라운드 사용 제한
                AS: 자동 시작 | 자동 실행 | autostart | 자동시작
                LK: vpn 없이 연결 차단 | vpn 없는 연결 차단 | vpn을 사용하지 않는 연결 차단
                UT: 사용자 | 다중 사용자
            """,
        )
    }
}
