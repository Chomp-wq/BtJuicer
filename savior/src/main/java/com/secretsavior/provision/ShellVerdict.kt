package com.secretsavior.provision

/**
 * Qué se le pide al teléfono por ADB inalámbrico y cómo se traduce lo que contesta.
 * Sin Android: así se prueba suelto. Lo que devuelven `pm` y `dpm` es texto en inglés fijo
 * (no depende del idioma del teléfono), pero cada fabricante lo adorna a su manera.
 */
object ShellVerdict {

    enum class Goal {
        /** `WRITE_SECURE_SETTINGS`: la app reenciende sola su accesibilidad. */
        SECURE_SETTINGS,

        /** Propietaria del dispositivo. De ida: la única salida es restablecer de fábrica. */
        DEVICE_OWNER,
    }

    const val PACKAGE = "com.secretsavior"
    const val ADMIN = "$PACKAGE/.guard.AdminReceiver"

    fun command(goal: Goal): String = when (goal) {
        Goal.SECURE_SETTINGS -> "pm grant $PACKAGE android.permission.WRITE_SECURE_SETTINGS"
        Goal.DEVICE_OWNER -> "dpm set-device-owner $ADMIN"
    }

    /** El mismo comando para teclearlo desde un ordenador. */
    fun pcCommand(goal: Goal): String = "adb shell " + command(goal)

    data class Verdict(val ok: Boolean, val message: String)

    /**
     * [verified]: el sistema ya muestra el cambio (permiso concedido / app propietaria). Pesa más
     * que el texto: `dpm` contesta de formas distintas según el fabricante, y «ya era propietaria»
     * también es un éxito.
     */
    fun interpret(goal: Goal, output: String, verified: Boolean): Verdict {
        val text = output.trim()
        val low = text.lowercase()
        if (verified) {
            return Verdict(
                true,
                when (goal) {
                    Goal.SECURE_SETTINGS -> "Hecho: la app puede volver a encender su propio guardián."
                    Goal.DEVICE_OWNER -> "Hecho: Secret Savior es propietaria del dispositivo. Ya puedes volver a añadir tus cuentas."
                },
            )
        }
        val why = when {
            "already some accounts" in low || ("accounts" in low && "already" in low) ->
                "Android no deja hacerlo con cuentas en el teléfono. Quita todas en Ajustes → Cuentas " +
                    "(Google, Xiaomi y las de apps como WhatsApp o Telegram), repite y luego vuélvelas a añadir."

            "several users" in low || ("users" in low && "already" in low) ->
                "Hay más de un usuario o espacio en el teléfono. Quita el «Segundo espacio», las " +
                    "«Apps duales» y los usuarios o invitados extra, y repite."

            "device owner" in low && "already set" in low ->
                "Ya hay otra app como propietaria del dispositivo. Hay que quitarla antes (o restablecer de fábrica)."

            "grant_runtime_permissions" in low || "manage_device_admins" in low ||
                "write_secure_settings" in low || "securityexception" in low ||
                "permission denial" in low ->
                "Xiaomi/HyperOS exige además activar «Depuración USB (ajustes de seguridad)» en " +
                    "Opciones de desarrollador (pide iniciar sesión con cuenta Xiaomi y tarjeta SIM). Actívala y repite."

            "unknown command" in low || "not found" in low ->
                "Este teléfono no reconoce el comando. Prueba desde un ordenador con el comando de arriba."

            else -> "No se aplicó el cambio."
        }
        val tail = if (text.isEmpty()) "" else "\n\nEl teléfono contestó:\n$text"
        return Verdict(false, why + tail)
    }

    /** Los seis dígitos que enseña Ajustes; null si lo escrito no lo es. */
    fun parseCode(input: CharSequence?): String? {
        val digits = input?.filter { it.isDigit() }?.toString().orEmpty()
        return digits.takeIf { it.length == 6 }
    }
}
