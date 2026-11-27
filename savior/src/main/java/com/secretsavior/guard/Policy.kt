package com.secretsavior.guard

/**
 * Qué hace el guardián con una pantalla del sistema, decidido sobre lo que ya se leyó de ella.
 * Sin Android: así lo que importa (que en cualquier idioma no se llegue a «Forzar detención»,
 * pero que el instalador y las listas del optimizador sigan funcionando) se prueba con JUnit.
 */
object Policy {

    enum class Surface {
        /** Ajustes del sistema (y sus variantes: com.android.settings, com.samsung...settings). */
        SETTINGS,

        /** Apps de seguridad/batería del fabricante: Seguridad de Xiaomi, Device Care... */
        VENDOR,

        INSTALLER,
        VPN_DIALOGS,

        /** Controlador de permisos. */
        PERMISSIONS,
    }

    /** Lo mismo que Store.Grace; copia propia para que esto no dependa de Android. */
    enum class Grace { BATTERY, AUTOSTART, NOTIFICATION_ACCESS, ALWAYS_ON_VPN, AUTO_REVOKE }

    class Input(
        val surface: Surface,
        /** Todos los conceptos vistos en la pantalla (ver [Concept]). */
        val mask: Int,
        /** Clase de la ventana (ver [WinKind]). */
        val kind: Int,
        /** Algún nodo tiene un id tipo force_stop/uninstall/clear_data. */
        val dangerId: Boolean,
        /** Cuántos nodos con texto: pocos = aún carga, o es un diálogo. */
        val texts: Int,
        /** Lista de interruptores titulada «autoinicio» (o clase de autoinicio). */
        val autostartList: Boolean,
        /** Idioma sin traducción ni lectura de los Ajustes: las palabras no son de fiar. */
        val strict: Boolean,
        val grace: Grace?,
        val adminActive: Boolean,
        val privateDnsStrict: Boolean,
        val vpnPermitted: Boolean,
        val devBlocked: Boolean,
        /** Hace poco se vio una pantalla que nombraba a la app. */
        val recentOurs: Boolean,
        /** Segundo espacio de Xiaomi (com.miui.securitycore): cualquier fila de usuarios cierra. */
        val secondSpaceSurface: Boolean = false,
    )

    class Verdict(
        val close: Boolean,
        /** Conceptos cuyas filas se tapan. */
        val shield: Int,
        /** Tapar las filas que nombran a la app. */
        val shieldOurs: Boolean,
        /** Tapar los nodos con id de botón peligroso (en pantallas que nombran a la app). */
        val shieldIds: Boolean,
        /** La pantalla aún no cargó: la capa grande se queda y se vuelve a mirar. */
        val keepCover: Boolean,
    )

    /** Con al menos tantos textos, una pantalla de Ajustes o del fabricante ya ha cargado. */
    const val LOADED_TEXTS = 4

    /** Un diálogo de confirmación tiene pocos textos: título, mensaje y dos botones. */
    const val DIALOG_MAX_TEXTS = 12

    private fun has(mask: Int, bits: Int) = mask and bits != 0

    /**
     * ¿La pantalla (que nombra a la app) se puede ver con la ventana abierta desde dentro de la app?
     * Nunca la ficha de la app con sus botones, el administrador, Accesibilidad ni la desinstalación.
     */
    fun graceAllows(g: Grace?, mask: Int, kind: Int, dangerId: Boolean, strict: Boolean): Boolean {
        if (g == null) return false
        if (has(kind, WinKind.ACCESSIBILITY or WinKind.ADMIN or WinKind.UNINSTALL or WinKind.USERS)) return false
        if (has(mask, Concept.DEACTIVATE_ADMIN or Concept.ACCESSIBILITY)) return false
        // En un idioma que no se conoce no se puede tapar «Bloquear conexiones sin VPN», ni las filas
        // de la ficha por su texto: esas dos ventanas no se abren.
        if (strict && g == Grace.ALWAYS_ON_VPN) return false
        if (strict && g == Grace.AUTO_REVOKE && has(kind, WinKind.APP_DETAILS)) return false
        if (g == Grace.AUTO_REVOKE) return true // tapadas las filas de parar/desinstalar/borrar datos
        if (dangerId || has(kind, WinKind.APP_DETAILS) || has(mask, Concept.STRONG or Concept.WEAK)) return false
        if (g != Grace.BATTERY && has(mask, Concept.RESTRICT_BACKGROUND)) return false
        if (g != Grace.ALWAYS_ON_VPN) {
            if (has(mask, Concept.VPN or Concept.VPN_DISCONNECT_FORGET) || has(kind, WinKind.VPN)) return false
        }
        return true
    }

    /**
     * El cierre que se decide sólo con el aviso de la ventana (título y clase), antes de leer nada:
     * llega a tiempo cuando la lectura de la pantalla llegaría tarde.
     */
    fun eventClose(
        settingsLike: Boolean,
        titleMask: Int,
        kind: Int,
        usersTitle: Boolean,
        adminActive: Boolean,
        grace: Grace?,
        strict: Boolean,
        devBlocked: Boolean,
    ): Boolean {
        // Accesibilidad no se vuelve a abrir mientras el guardián viva: sin excepciones ni gracia.
        if (has(titleMask, Concept.ACCESSIBILITY)) return true
        if (!settingsLike) return false
        if (has(kind, WinKind.ACCESSIBILITY)) return true
        if (has(kind, WinKind.USERS) || usersTitle) return true
        if (devBlocked && (has(kind, WinKind.DEV) || has(titleMask, Concept.DEVELOPER_OPTIONS))) return true
        if (adminActive && has(titleMask, Concept.OURS) &&
            !graceAllows(grace, Concept.OURS, kind, false, strict)
        ) {
            return true
        }
        return false
    }

    fun decide(i: Input): Verdict {
        val ours = has(i.mask, Concept.OURS)
        val strong = has(i.mask, Concept.STRONG)
        val settingsLike = i.surface == Surface.SETTINGS || i.surface == Surface.VENDOR
        val allowed = ours && graceAllows(i.grace, i.mask, i.kind, i.dangerId, i.strict)

        // Filas que se tapan (sólo Ajustes y fabricante dibujan capas).
        var shield = Concept.ACCESSIBILITY or Concept.USERS_SECOND_SPACE
        if (i.devBlocked) shield = shield or Concept.DEVELOPER_OPTIONS or Concept.BUILD_NUMBER
        if (ours) {
            shield = shield or Concept.STRONG or Concept.DEACTIVATE_ADMIN
            // En «Pausar si no se usa» el interruptor lleva «eliminar permisos»: no se tapa.
            if (i.grace != Grace.AUTO_REVOKE) shield = shield or Concept.WEAK
        }
        if (i.grace == Grace.ALWAYS_ON_VPN) shield = shield or Concept.VPN_DISCONNECT_FORGET or Concept.LOCKDOWN_TOGGLE
        val shieldOurs = ours && !allowed
        val keep = settingsLike && i.texts < LOADED_TEXTS

        fun verdict(close: Boolean) = Verdict(close, shield, shieldOurs, shieldIds = ours, keepCover = keep && !close)

        when (i.surface) {
            // Instalar una actualización nombra a la app sin ser un riesgo: sólo se cierra la
            // desinstalación (por su texto, por la clase de la ventana o por el id de su botón).
            Surface.INSTALLER -> return verdict(
                has(i.kind, WinKind.UNINSTALL) || has(i.mask, Concept.STRONG or Concept.DEACTIVATE_ADMIN) || i.dangerId,
            )
            // Sin permiso de VPN aún, el diálogo es el de pedirlo: se deja. Con permiso, cualquiera que
            // nombre a la app es el de «Desconectar».
            Surface.VPN_DIALOGS -> return verdict(i.vpnPermitted && ours)
            else -> Unit
        }

        // Accesibilidad no se abre nunca (aunque aún no haya administrador).
        if (settingsLike && has(i.kind, WinKind.ACCESSIBILITY)) return verdict(true)
        // Sin administrador activo el usuario necesita llegar a la pantalla de activarlo.
        if (!i.adminActive) return verdict(false)

        if (has(i.kind, WinKind.USERS)) return verdict(true)
        if (i.devBlocked && has(i.kind, WinKind.DEV)) return verdict(true)
        if (i.secondSpaceSurface && has(i.mask, Concept.USERS_SECOND_SPACE)) return verdict(true)
        // Un proxy manual resuelve el DNS fuera del teléfono y se salta el filtro.
        if (settingsLike && has(i.mask, Concept.PROXY_EDITOR)) return verdict(true)
        // El diálogo de confirmación de parar/desinstalar/borrar no nombra a la app: sólo pregunta.
        if (!ours && strong && i.texts <= DIALOG_MAX_TEXTS && i.recentOurs) return verdict(true)

        if (i.surface == Surface.VENDOR) {
            // Las listas del optimizador nombran a la app sin peligro (se congelaba la app de
            // Seguridad): sólo se cierra su ficha, reconocida por lo que ofrece (palabras, id de
            // botón, clase de la ventana) o, si el idioma no se conoce, por nombrar a la app.
            if (i.autostartList) return verdict(true)
            if (ours && (strong || i.dangerId || has(i.kind, WinKind.APP_DETAILS or WinKind.ADMIN) || i.strict)) {
                return verdict(true)
            }
            if (ours && has(i.mask, Concept.RESTRICT_BACKGROUND) && i.grace != Grace.BATTERY) return verdict(true)
            return verdict(false)
        }

        if (ours) return verdict(!allowed)
        // Con DNS privado estricto los navegadores quedan cerrados; hay que dejar llegar al editor
        // para quitarlo, o se quedarían cerrados para siempre.
        if (has(i.mask, Concept.PRIVATE_DNS_EDITOR) && !i.privateDnsStrict) return verdict(true)
        return verdict(false)
    }
}
