package com.example.lightdome_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object PlaybackCaptureBridge : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile var status: String = "stopped"
        private set
    @Volatile private var statusMessage: String = "Audio non attivo"

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emit(mapOf("type" to "status", "status" to status, "message" to statusMessage))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun updateStatus(next: String, message: String) {
        status = next
        statusMessage = message
        emit(mapOf("type" to "status", "status" to next, "message" to message))
    }

    fun emitPcm(pcm16: ByteArray, sampleRateHz: Int) {
        emit(
            mapOf(
                "type" to "pcm16",
                "sampleRateHz" to sampleRateHz,
                "channels" to 1,
                "data" to pcm16,
            ),
        )
    }

    private fun emit(event: Map<String, Any>) {
        mainHandler.post { sink?.success(event) }
    }
}
