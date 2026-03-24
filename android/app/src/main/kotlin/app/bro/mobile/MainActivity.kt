package app.bro.mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "app.bro.mobile/settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openBatterySettings") {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        intent.data = Uri.parse("package:${packageName}")
                        startActivity(intent)
                    } else {
                        val intent = Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                        startActivity(intent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    // Fallback to general battery settings
                    try {
                        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        startActivity(intent)
                        result.success(true)
                    } catch (e2: Exception) {
                        result.error("UNAVAILABLE", "Could not open battery settings", null)
                    }
                }
            } else if (call.method == "isIgnoringBatteryOptimizations") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                } else {
                    result.success(true)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
