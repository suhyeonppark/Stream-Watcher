package com.example.stream_watcher_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 알림 채널과 Notification 생성을 한곳에 모은다.
 * androidx 의존성을 추가하지 않으려고 프레임워크 API만 SDK 분기해서 쓴다.
 */
object AlertNotifications {
    const val CHANNEL_MONITOR = "stream_watcher_monitor"
    const val CHANNEL_ALERT = "stream_watcher_alert"

    const val ID_MONITOR = 1001
    const val ID_ALERT = 1002

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        // 상시 표시되는 "감시 중" 알림 — 조용해야 하므로 LOW.
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MONITOR,
                "방송 감시 중",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "PC와 연결을 유지하는 동안 표시됩니다."
                setShowBadge(false)
            }
        )

        // 실제 경고 — 화면이 꺼져 있어도 떠야 하므로 HIGH + 알람 취급.
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ALERT,
                "방송 경고",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "송출 문제가 감지되면 즉시 알립니다."
                enableVibration(true)
                enableLights(true)
            }
        )
    }

    fun contentIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    fun monitoring(context: Context): Notification =
        builder(context, CHANNEL_MONITOR)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("방송 감시 중")
            .setContentText("PC와 연결을 유지하고 있습니다")
            .setContentIntent(contentIntent(context))
            .setOngoing(true)
            .setShowWhen(false)
            .apply {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    setPriority(Notification.PRIORITY_LOW)
                }
            }
            .build()

    fun alert(context: Context, title: String, message: String, critical: Boolean): Notification =
        builder(context, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(message)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .setContentIntent(contentIntent(context))
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .apply {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    setPriority(
                        if (critical) Notification.PRIORITY_MAX else Notification.PRIORITY_HIGH
                    )
                }
            }
            .build()

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            Notification.Builder(context)
        }
}
