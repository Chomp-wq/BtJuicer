package com.btjuicer.service

import android.os.Build
import android.os.Bundle
import android.util.Log
import org.json.JSONObject

/**
 * Xiaomi's "isla dinámica" — the capsule around the front camera on HyperOS.
 *
 * ### What this is, and what it is not
 *
 * Android has no API for it. HyperOS drives that capsule from a **private
 * extension to the notification format**: a JSON blob under the key
 * `miui.focus.param`, which Xiaomi's system UI reads and everyone else ignores.
 * There is no public documentation and no compatibility promise, so what follows
 * is written from the shape the system is known to accept.
 *
 * It is worth being straight about the odds. On most HyperOS builds Xiaomi
 * **gates this by package**: system apps and a handful of partners are allowed,
 * and an unlisted app's blob is dropped without a word. Sending it costs
 * nothing, breaks nothing, and does nothing at all on any other phone — the
 * extras are simply unread. So it is worth trying and not worth promising.
 *
 * If it does not appear, the notification underneath is a perfectly ordinary one
 * and behaves normally.
 */
internal object FocusNotification {

    private const val TAG = "BTJuicer"

    private const val KEY_PARAM = "miui.focus.param"
    private const val KEY_PARAM_V2 = "miui.focus.paramV2"

    /** Only Xiaomi's own ROMs read these keys; elsewhere it is dead weight. */
    private val isXiaomi: Boolean
        get() = listOf(Build.MANUFACTURER, Build.BRAND).any {
            it.equals("Xiaomi", true) || it.equals("Redmi", true) || it.equals("POCO", true)
        }

    /**
     * @param title the line the capsule shows when expanded.
     * @param detail the smaller line under it.
     * @param ticker the short text shown while collapsed — this is the one that
     *   has to fit beside a camera hole, so it gets the codec and nothing else.
     */
    fun decorate(extras: Bundle, title: String, detail: String, ticker: String) {
        if (!isXiaomi) return
        runCatching {
            val json = JSONObject().apply {
                put("protocol", 1)
                put("enableFloat", true)
                // Updatable, so re-posting the same notification animates the
                // capsule instead of making it pop in again on every route change.
                put("updatable", true)
                put("ticker", ticker)
                put("tickerPic", "ic_notification")
                put("timeout", 0)
                put(
                    "baseInfo",
                    JSONObject().apply {
                        put("type", 1)
                        put("title", title)
                        put("content", detail)
                    },
                )
            }.toString()

            extras.putString(KEY_PARAM, json)
            extras.putString(KEY_PARAM_V2, json)
        }.onFailure {
            // Never fatal: the notification has to go out either way, and a
            // foreground service that fails to post one gets killed.
            Log.w(TAG, "focus notification extras failed", it)
        }
    }
}
