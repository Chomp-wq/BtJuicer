package com.secretsavior.guard

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri

/**
 * Qué apps son navegadores. La lista fija cubre los conocidos; además se pregunta al sistema qué
 * apps abren una dirección web cualquiera, para que un navegador poco conocido no se salte el
 * cierre del navegador cuando el filtro está caído.
 */
object Browsers {

    val KNOWN: Set<String> = setOf(
        "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary",
        "com.google.android.apps.chrome", "org.mozilla.firefox", "org.mozilla.firefox_beta",
        "org.mozilla.fenix", "org.mozilla.focus", "org.mozilla.klar", "com.sec.android.app.sbrowser",
        "com.brave.browser", "com.microsoft.emmx", "com.opera.browser", "com.opera.mini.native",
        "com.duckduckgo.mobile.android", "com.kiwibrowser.browser", "com.vivaldi.browser",
        "com.UCMobile.intl", "com.android.browser", "com.mi.globalbrowser", "com.huawei.browser",
        "org.chromium.webview_shell", "org.torproject.torbrowser",
    )

    @Volatile
    private var all: Set<String> = KNOWN

    /** Los conocidos más los que el sistema dice que abren webs (tras [refresh]). */
    fun all(): Set<String> = all

    /** Pregunta al sistema. Necesita el `<queries>` del manifiesto. Nunca lanza. */
    fun refresh(c: Context) {
        val found = HashSet<String>(KNOWN)
        try {
            val pm = c.packageManager
            for (scheme in listOf("http", "https")) {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://example.com/"))
                    .addCategory(Intent.CATEGORY_BROWSABLE)
                for (ri in pm.queryIntentActivities(intent, PackageManager.MATCH_ALL)) {
                    ri.activityInfo?.packageName?.let(found::add)
                }
            }
        } catch (e: Throwable) {
            // sin respuesta del sistema: quedan los conocidos
        }
        found.remove(c.packageName)
        all = found
    }
}
