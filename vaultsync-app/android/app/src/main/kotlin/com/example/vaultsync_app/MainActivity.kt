package com.example.vaultsync_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "vaultsync/background_sync",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, SyncKeepAliveService::class.java)
                    startSyncService(intent)
                    result.success(null)
                }
                "setTransferActive" -> {
                    val active = call.argument<Boolean>("active") == true
                    val intent = Intent(this, SyncKeepAliveService::class.java).apply {
                        putExtra(SyncKeepAliveService.EXTRA_TRANSFER_ACTIVE, active)
                    }
                    startSyncService(intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, SyncKeepAliveService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startSyncService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
