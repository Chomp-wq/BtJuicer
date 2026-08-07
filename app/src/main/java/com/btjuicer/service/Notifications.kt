package com.btjuicer.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.btjuicer.MainActivity
import com.btjuicer.R
import com.btjuicer.audio.EngineState
import com.btjuicer.bt.LinkInfo

object Notifications {

    const val CHANNEL_STATUS = "status"
    const val CHANNEL_REMINDER = "reminder"

    const val ID_STATUS = 1
    const val ID_REMINDER = 2

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_STATUS,
                context.getString(R.string.channel_status),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.channel_status_desc)
                setShowBadge(false)
            },
        )

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_REMINDER,
                context.getString(R.string.channel_reminder),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.channel_reminder_desc)
            },
        )
    }

    fun status(
        context: Context,
        engine: EngineState,
        link: LinkInfo,
        codecLabel: String? = null,
    ): Notification {
        val title = when (engine) {
            is EngineState.Active -> context.getString(R.string.notif_eq_on)
            is EngineState.Failed -> context.getString(R.string.notif_eq_failed)
            EngineState.Off -> context.getString(R.string.notif_eq_off)
        }

        val detail = buildString {
            append(link.route.label)
            if (link.btDeviceName.isNotEmpty()) append(" · ").append(link.btDeviceName)
            if (link.mixerSampleRateHz > 0) {
                append(" · ").append("%.1f kHz".format(link.mixerSampleRateHz / 1000.0))
            }
        }

        // Short enough to sit beside a camera hole: the codec if we know it,
        // otherwise where the sound is going.
        val ticker = codecLabel?.takeIf { it.isNotEmpty() }
            ?: link.btDeviceName.takeIf { it.isNotEmpty() }
            ?: link.route.label

        val extras = Bundle().also { FocusNotification.decorate(it, title, detail, ticker) }

        return NotificationCompat.Builder(context, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(detail)
            .setSubText(ticker)
            .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setColorized(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openApp(context))
            .addExtras(extras)
            .addAction(
                R.drawable.ic_notification,
                context.getString(
                    if (engine is EngineState.Active) R.string.action_eq_off else R.string.action_eq_on,
                ),
                serviceCommand(context, JuicerService.ACTION_TOGGLE_EQ, 10),
            )
            .build()
    }

    /**
     * Fired when a Bluetooth output connects, because that is exactly the moment
     * Android may have quietly dropped the LDAC quality setting back to
     * adaptive — and the only place that can be fixed is Developer Options.
     */
    fun remindChecklist(context: Context, deviceName: String) {
        val text = context.getString(
            R.string.notif_reminder_body,
            deviceName.ifEmpty { context.getString(R.string.unknown_device) },
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDER)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.notif_reminder_title))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(openApp(context))
            .addAction(
                R.drawable.ic_notification,
                context.getString(R.string.action_open_developer_options),
                developerOptions(context),
            )
            .build()

        runCatching { NotificationManagerCompat.from(context).notify(ID_REMINDER, notification) }
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    private fun developerOptions(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        1,
        Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE,
    )

    private fun serviceCommand(context: Context, action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            context,
            requestCode,
            Intent(context, JuicerService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
}
