package com.example.stream_watcher_mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 앱이 백그라운드로 가거나 화면이 꺼져도 프로세스가 살아 있게 붙잡아 두는 서비스.
 *
 * 이게 없으면 Android가 Flutter 프로세스를 정지시키거나 Doze로 네트워크를 끊어,
 * SSE 연결이 조용히 죽고 알림이 한 건도 오지 않는다.
 */
class MonitorService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        AlertNotifications.ensureChannels(this)
        val notification = AlertNotifications.monitoring(this)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                AlertNotifications.ID_MONITOR,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(AlertNotifications.ID_MONITOR, notification)
        }

        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "StreamWatcher::monitor",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }

        // 시스템이 프로세스를 잠깐 죽여도 서비스는 되살린다.
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, MonitorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MonitorService::class.java))
        }
    }
}
