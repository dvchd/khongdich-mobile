package com.khongdich.khongdich_mobile

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// MainActivity phải extend `AudioServiceActivity` (audio_service) thay
/// vì `FlutterActivity` thuần. AudioServiceActivity trả về engine được
/// cache dưới id "audio_service_engine" (AudioServicePlugin) — nếu không,
/// plugin tạo MỘT ENGINE THỨ HAI riêng → `wrongEngineDetected = true` →
/// `AudioService.init` throw PlatformException ("Activity class declared
/// in your AndroidManifest.xml is wrong...") → media notification KHÔNG
/// BAO GIỜ hiển thị, điều khiển ngoài app chết hoàn toàn. Đây là root
/// cause của "ẩn app không điều khiển được" trên mọi build (kể cả
/// release).
class MainActivity : AudioServiceActivity() {
    private val notificationsChannel = "khongdich/notifications"
    private val ttsSettingsChannel = "khongdich/tts_settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            notificationsChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestNotificationPermission(result)
                "hasPermission" -> result.success(hasNotificationPermission())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ttsSettingsChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openTtsSettings" -> result.success(openTtsSettings())
                else -> result.notImplemented()
            }
        }
    }

    /// Mở màn "Text-to-speech output" của hệ thống — nơi user cập nhật
    /// engine, tải dữ liệu giọng (voice data) tiếng Việt. Intent
    /// `com.android.settings.TTS_SETTINGS` không nằm trong public API
    /// nhưng hỗ trợ rộng rãi trên Android gốc và phần lớn OEM. Máy không
    /// hỗ trợ → fallback về Cài đặt chung (user tự vào Accessibility →
    /// Text-to-speech output). Trả false khi cả hai đều không mở được.
    private fun openTtsSettings(): Boolean {
        val ttsIntent = Intent("com.android.settings.TTS_SETTINGS")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(ttsIntent)
            true
        } catch (e: ActivityNotFoundException) {
            try {
                startActivity(
                    Intent(Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                true
            } catch (e2: Exception) {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        // The async permission dialog result is delivered to
        // onRequestPermissionsResult; answer optimistically now and let the
        // OS dialog drive the actual grant. Re-check via hasPermission on
        // the next call.
        result.success(false)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // POST_NOTIFICATIONS granted/denied — nothing else needed here;
        // audio_service picks the grant up on the next notification post.
    }
}
