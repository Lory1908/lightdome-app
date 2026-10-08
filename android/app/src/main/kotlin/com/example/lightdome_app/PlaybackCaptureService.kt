package com.example.lightdome_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class PlaybackCaptureService : Service() {
    companion object {
        const val ACTION_START = "com.example.lightdome_app.START_PLAYBACK_CAPTURE"
        const val ACTION_STOP = "com.example.lightdome_app.STOP_PLAYBACK_CAPTURE"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val CHANNEL_ID = "lightdome_audio_capture"
        private const val NOTIFICATION_ID = 2901
        private const val SAMPLE_RATE_HZ = 48_000
        private const val FRAME_SAMPLES = 1024
    }

    private val stopping = AtomicBoolean(false)
    private var projection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var worker: Thread? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stopCapture("Autorizzazione audio terminata", false)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopCapture("Audio fermato", true)
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START) return START_NOT_STICKY
        startAsForeground()
        try {
            startCapture(intent)
        } catch (error: Throwable) {
            failCapture(error.message ?: "Impossibile avviare l’audio del telefono")
        }
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Audio LightDome",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Indica quando LightDome analizza l’audio riprodotto" },
            )
        }
        val stopIntent = Intent(this, PlaybackCaptureService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("LightDome ascolta l’audio del telefono")
            .setContentText("Tocca Ferma per interrompere la condivisione")
            .setOngoing(true)
            .setSilent(true)
            .addAction(android.R.drawable.ic_media_pause, "Ferma", stopPendingIntent)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun projectionData(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }

    private fun startCapture(intent: Intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("Richiede Android 10 o successivo")
        }
        stopCaptureResources(false)
        stopping.set(false)
        val resultData = projectionData(intent) ?: error("Consenso MediaProjection mancante")
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val nextProjection = projectionManager.getMediaProjection(resultCode, resultData)
            ?: error("Consenso MediaProjection non valido")
        nextProjection.registerCallback(projectionCallback, null)
        projection = nextProjection

        val captureConfig = android.media.AudioPlaybackCaptureConfiguration.Builder(nextProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE_HZ)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minimum = AudioRecord.getMinBufferSize(
            SAMPLE_RATE_HZ,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val nextRecord = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minimum, FRAME_SAMPLES * 2 * 4))
            .setAudioPlaybackCaptureConfig(captureConfig)
            .build()
        if (nextRecord.state != AudioRecord.STATE_INITIALIZED) {
            nextRecord.release()
            error("Il dispositivo non ha inizializzato la cattura audio")
        }
        audioRecord = nextRecord
        nextRecord.startRecording()
        PlaybackCaptureBridge.updateStatus("running", "Audio del telefono attivo")
        worker = thread(name = "LightDomePlaybackCapture", isDaemon = true) {
            captureLoop(nextRecord)
        }
    }

    private fun captureLoop(record: AudioRecord) {
        val samples = ShortArray(FRAME_SAMPLES)
        while (!stopping.get()) {
            val count = record.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
            if (count > 0) {
                val bytes = ByteArray(count * 2)
                for (index in 0 until count) {
                    val value = samples[index].toInt()
                    bytes[index * 2] = (value and 0xff).toByte()
                    bytes[index * 2 + 1] = ((value ushr 8) and 0xff).toByte()
                }
                PlaybackCaptureBridge.emitPcm(bytes, SAMPLE_RATE_HZ)
            } else if (count < 0 && !stopping.get()) {
                failCapture("La sorgente audio si è interrotta")
                return
            }
        }
    }

    private fun stopCapture(message: String, stopProjection: Boolean) {
        if (!stopping.compareAndSet(false, true)) return
        stopCaptureResources(stopProjection)
        PlaybackCaptureBridge.updateStatus("stopped", message)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun failCapture(message: String) {
        if (!stopping.compareAndSet(false, true)) return
        stopCaptureResources(true)
        PlaybackCaptureBridge.updateStatus("error", message)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopCaptureResources(stopProjection: Boolean) {
        val record = audioRecord
        audioRecord = null
        try {
            record?.stop()
        } catch (_: IllegalStateException) {
        }
        record?.release()
        worker?.interrupt()
        worker = null
        val currentProjection = projection
        projection = null
        currentProjection?.unregisterCallback(projectionCallback)
        if (stopProjection) currentProjection?.stop()
    }

    override fun onDestroy() {
        if (!stopping.get()) {
            stopping.set(true)
            stopCaptureResources(true)
            PlaybackCaptureBridge.updateStatus("stopped", "Servizio audio terminato")
        }
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopCapture("App chiusa: audio fermato", true)
        super.onTaskRemoved(rootIntent)
    }
}
