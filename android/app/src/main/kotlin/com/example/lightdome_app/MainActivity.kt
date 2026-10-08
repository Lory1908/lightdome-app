package com.example.lightdome_app

import android.Manifest
import android.app.Activity.RESULT_OK
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "lightdome/audio_playback_capture"
        private const val EVENT_CHANNEL = "lightdome/audio_playback_capture/events"
        private const val PERMISSION_REQUEST = 8041
        private const val PROJECTION_REQUEST = 8042
    }

    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(PlaybackCaptureBridge)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "availability" -> result.success(
                mapOf(
                    "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                    "sdk" to Build.VERSION.SDK_INT,
                    "status" to PlaybackCaptureBridge.status,
                ),
            )
            "start" -> startCapture(result)
            "stop" -> {
                val intent = Intent(this, PlaybackCaptureService::class.java)
                    .setAction(PlaybackCaptureService.ACTION_STOP)
                startService(intent)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startCapture(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Audio del telefono richiede Android 10 o successivo.", null)
            return
        }
        if (pendingStartResult != null) {
            result.error("busy", "È già in corso una richiesta di autorizzazione.", null)
            return
        }
        if (PlaybackCaptureBridge.status == "running" || PlaybackCaptureBridge.status == "starting") {
            result.success(null)
            return
        }
        pendingStartResult = result
        val permissions = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissions += Manifest.permission.RECORD_AUDIO
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            permissions += Manifest.permission.POST_NOTIFICATIONS
        }
        if (permissions.isNotEmpty()) {
            requestPermissions(permissions.toTypedArray(), PERMISSION_REQUEST)
        } else {
            requestProjectionConsent()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pendingStartResult?.error("record_audio_denied", "Il permesso audio è necessario per analizzare la riproduzione.", null)
            pendingStartResult = null
            return
        }
        // Android 13+ may hide the notification when this permission is denied,
        // but the foreground service is still visible in the system task manager.
        requestProjectionConsent()
    }

    private fun requestProjectionConsent() {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), PROJECTION_REQUEST)
    }

    @Deprecated("Kept for the MediaProjection consent flow supported by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PROJECTION_REQUEST) return
        val pending = pendingStartResult
        pendingStartResult = null
        if (resultCode != RESULT_OK || data == null) {
            pending?.error("projection_denied", "Condivisione audio annullata.", null)
            return
        }
        PlaybackCaptureBridge.updateStatus("starting", "Avvio della cattura audio…")
        val serviceIntent = Intent(this, PlaybackCaptureService::class.java)
            .setAction(PlaybackCaptureService.ACTION_START)
            .putExtra(PlaybackCaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(PlaybackCaptureService.EXTRA_RESULT_DATA, data)
        ContextCompat.startForegroundService(this, serviceIntent)
        pending?.success(null)
    }
}
