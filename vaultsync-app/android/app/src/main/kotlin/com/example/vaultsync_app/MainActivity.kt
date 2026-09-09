package com.example.vaultsync_app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private companion object {
        const val FILE_PROVIDER_AUTHORITY = "com.example.vaultsync_app.fileprovider"
    }

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
                "openExternalMedia" -> openExternalMedia(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun openExternalMedia(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path")?.trim()
        if (path.isNullOrEmpty()) {
            result.error("invalid_path", "媒体文件路径为空", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("file_not_found", "媒体文件不存在", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
            .ifEmpty { "video/mp4" }
        val uri = FileProvider.getUriForFile(this, FILE_PROVIDER_AUTHORITY, file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            clipData = ClipData.newRawUri("VaultSync media", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        }
        try {
            startActivity(intent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
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
