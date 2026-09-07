package com.example.stream_watcher_mobile

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val pattern = longArrayOf(0, 180, 120, 180, 120, 260, 160, 360)

    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stream_watcher_mobile/alerts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "vibrateAlert" -> {
                        vibrate(-1)
                        result.success(null)
                    }
                    "startAlertVibration" -> {
                        // repeat index 0 → 취소(stop)할 때까지 패턴을 무한 반복
                        vibrate(0)
                        result.success(null)
                    }
                    "stopAlertVibration" -> {
                        vibrator.cancel()
                        result.success(null)
                    }
                    "hasVibrator" -> {
                        result.success(vibrator.hasVibrator())
                    }
                    "getDeviceName" -> {
                        result.success(resolveDeviceName())
                    }
                    "startMonitoringService" -> {
                        ensureNotificationPermission()
                        MonitorService.start(this)
                        result.success(null)
                    }
                    "stopMonitoringService" -> {
                        MonitorService.stop(this)
                        result.success(null)
                    }
                    "showAlertNotification" -> {
                        showAlert(
                            call.argument<String>("title") ?: "방송 경고",
                            call.argument<String>("message") ?: "",
                            call.argument<Boolean>("critical") ?: false,
                        )
                        result.success(null)
                    }
                    "cancelAlertNotification" -> {
                        notificationManager.cancel(AlertNotifications.ID_ALERT)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private val notificationManager: NotificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    // Android 13+는 알림 권한을 사용자가 직접 허용해야 한다.
    // 거부해도 인앱 진동/플래시는 그대로 동작하므로 결과를 따로 처리하지 않는다.
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun showAlert(title: String, message: String, critical: Boolean) {
        AlertNotifications.ensureChannels(this)
        notificationManager.notify(
            AlertNotifications.ID_ALERT,
            AlertNotifications.alert(this, title, message, critical),
        )
    }

    // 사용자가 설정한 기기 이름(예: "수현의 Galaxy") → 없으면 제조사+모델명
    private fun resolveDeviceName(): String {
        val settingsName = try {
            Settings.Global.getString(contentResolver, "device_name")
        } catch (e: Exception) {
            null
        }
        if (!settingsName.isNullOrBlank()) return settingsName
        val manufacturer = (Build.MANUFACTURER ?: "").replaceFirstChar { it.uppercase() }
        val model = Build.MODEL ?: ""
        val combined = listOf(manufacturer, model).filter { it.isNotBlank() }.joinToString(" ").trim()
        return if (combined.isNotBlank()) combined else "Mobile"
    }

    private fun vibrate(repeat: Int) {
        // 진동 모터가 없는 기기(상당수 샤오미/태블릿)는 조용히 무시
        if (!vibrator.hasVibrator()) return
        when {
            // Android 13+: USAGE_ALARM 속성으로 무음/방해금지 억제 우회
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                val effect = VibrationEffect.createWaveform(pattern, repeat)
                val attrs = VibrationAttributes.Builder()
                    .setUsage(VibrationAttributes.USAGE_ALARM)
                    .build()
                vibrator.vibrate(effect, attrs)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, repeat))
            }
            else -> {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, repeat)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        vibrator.cancel()
    }
}
