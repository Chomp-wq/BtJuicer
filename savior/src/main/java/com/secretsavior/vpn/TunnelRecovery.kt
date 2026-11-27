package com.secretsavior.vpn

/** Decisiones puras de recuperación del túnel, para probarlas sin Android. */
object TunnelRecovery {
    /**
     * Tras un error de lectura del túnel: ¿reintentar o salir? Salir rehace la VPN y corta todas las
     * conexiones del teléfono, así que un error suelto no lo justifica; sólo si persiste ([errors]
     * seguidos por encima de [max]: descriptor muerto) o si el servicio ya se está destruyendo.
     */
    fun retryRead(destroyed: Boolean, errors: Int, max: Int): Boolean = !destroyed && errors <= max
}
