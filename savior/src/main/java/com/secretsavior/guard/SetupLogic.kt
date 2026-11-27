package com.secretsavior.guard

import androidx.core.content.UnusedAppRestrictionsConstants as U

/** Lógica pura de la configuración inicial (sin Android a pie de prueba), usada por [GuardService] y [Status]. */

/**
 * ¿Un interruptor del fabricante está encendido? El `SlidingButton` de MIUI no siempre marca
 * `isChecked`: a veces sólo lo dice con texto ("Activado") en el estado o la descripción.
 */
object SwitchText {
    private val ON = setOf(
        "on", "enabled", "activado", "activada", "encendido", "encendida", "habilitado", "habilitada",
        "ativado", "ativada", "active", "activé", "activée", "aktiviert", "eingeschaltet", "attivato",
        "attivo", "ingeschakeld", "włączone", "включено", "включён", "увімкнено", "açık", "pornit",
        "zapnuto", "bekapcsolva", "ενεργό", "مفعل", "פעיל", "روشن", "aktif", "bật", "เปิด",
        "켜짐", "オン", "有効",
    )
    private val OFF = setOf(
        "off", "disabled", "desactivado", "desactivada", "apagado", "apagada", "deshabilitado",
        "deshabilitada", "desativado", "desativada", "inactive", "désactivé", "désactivée",
        "deaktiviert", "ausgeschaltet", "disattivato", "uitgeschakeld", "wyłączone", "выключено",
        "выключен", "вимкнено", "kapalı", "oprit", "vypnuto", "kikapcsolva", "ανενεργό", "معطل",
        "כבוי", "خاموش", "nonaktif", "tắt", "ปิด", "꺼짐", "オフ", "無効",
    )

    // En chino no hay espacios entre palabras: se busca por trozo (y lo negativo va primero: «未开启»).
    private val OFF_CJK = listOf("未开启", "未開啟", "未启用", "未啟用", "已关闭", "已關閉", "已禁用", "关闭", "關閉", "禁用")
    private val ON_CJK = listOf("已开启", "已開啟", "已打开", "已打開", "已启用", "已啟用", "开启", "開啟", "启用", "啟用")

    /** true = dice «encendido», false = dice «apagado», null = no dice nada útil. */
    fun says(text: CharSequence?): Boolean? {
        if (text.isNullOrBlank()) return null
        val s = text.toString().lowercase()
        if (OFF_CJK.any { s.contains(it) }) return false
        if (ON_CJK.any { s.contains(it) }) return true
        var on = false
        var off = false
        var i = 0
        while (i < s.length) {
            if (!s[i].isLetter()) { i++; continue }
            var j = i
            while (j < s.length && s[j].isLetter()) j++
            val w = s.substring(i, j)
            if (w in OFF) off = true else if (w in ON) on = true
            i = j
        }
        return if (off) false else if (on) true else null
    }

    /** `isChecked` manda; si no, vale lo que digan los textos (y nada que diga «apagado»). */
    fun isOn(checked: Boolean, vararg texts: CharSequence?): Boolean {
        if (checked) return true
        var on = false
        for (t in texts) when (says(t)) {
            false -> return false
            true -> on = true
            null -> {}
        }
        return on
    }
}

/** «Pausar la actividad si no se usa» según androidx (`PackageManagerCompat.getUnusedAppRestrictionsStatus`). */
object UnusedApps {
    /**
     * Hecho = no hay función o está desactivada. Pendiente = Android puede pausar la app. Con
     * error o un valor nuevo que no conocemos no se bloquea (un ROM raro no debe impedir terminar).
     */
    fun isDone(status: Int?): Boolean = when (status) {
        null -> true
        U.FEATURE_NOT_AVAILABLE, U.DISABLED -> true
        U.API_30_BACKPORT, U.API_30, U.API_31 -> false
        else -> true
    }
}
