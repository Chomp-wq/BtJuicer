package com.btjuicer

import android.content.Context
import com.btjuicer.adb.AdbLink
import com.btjuicer.adb.CodecRepository
import com.btjuicer.audio.AudioEngine
import com.btjuicer.bt.LinkMonitor
import com.btjuicer.data.Prefs
import com.btjuicer.data.ProfileStore

/**
 * Process-wide singletons.
 *
 * Not an `Application` subclass on purpose — nothing here needs to run before
 * the first screen or service, and every entry point calls [init] first.
 */
object Juicer {

    private val lock = Any()

    @Volatile
    private var started = false

    private lateinit var appContext: Context

    val prefs: Prefs by lazy { Prefs(appContext) }
    val profiles: ProfileStore by lazy { ProfileStore(appContext) }
    val engine: AudioEngine by lazy { AudioEngine() }
    val link: LinkMonitor by lazy { LinkMonitor(appContext) }
    val adb: AdbLink by lazy { AdbLink(appContext) }
    val codec: CodecRepository by lazy { CodecRepository(adb, appContext) }

    /** Idempotent; safe from every entry point on every launch. */
    fun init(context: Context) {
        synchronized(lock) {
            if (started) return
            appContext = context.applicationContext
            started = true
        }
        // Restores the "already paired" badge without touching the network.
        adb.markPaired(prefs.current.adbPaired)
    }
}
