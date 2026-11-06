package com.fetchnet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel

/** What the YouTube player is showing, sent from Dart. */
data class MediaState(
    val title: String,
    val artist: String,
    val art: Bitmap?,
    val durationMs: Long,
    val positionMs: Long,
    val playing: Boolean,
    val speed: Float,
    val canPrevious: Boolean,
    val canNext: Boolean,
)

/** Connects the Dart player with [MediaPlaybackService]. */
object MediaBridge {
    private val main = Handler(Looper.getMainLooper())

    @Volatile var events: EventChannel.EventSink? = null
    @Volatile var state: MediaState? = null

    /** play | pause | next | previous | seek (with [position]) | stop. */
    fun emit(action: String, position: Long? = null) {
        main.post { events?.success(mapOf("action" to action, "position" to position)) }
    }

    fun update(context: Context, s: MediaState) {
        state = s
        val service = MediaPlaybackService.instance
        if (service != null) {
            service.render()
        } else {
            try {
                ContextCompat.startForegroundService(context, Intent(context, MediaPlaybackService::class.java))
            } catch (_: Exception) {
                // Not allowed from the background right now; the next update retries.
            }
        }
    }

    fun stop() {
        state = null
        MediaPlaybackService.instance?.stopNow()
    }
}

/**
 * The player's media notification and media session: lock screen / quick
 * settings controls, headset buttons, and playback that keeps going while
 * FetchNet is in the background (Listen only).
 */
class MediaPlaybackService : Service() {

    private lateinit var session: MediaSession
    private val audio by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private var pausedForFocus = false
    private var noisyRegistered = false
    private var foreground = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            // A call, or another app playing: pause like any media app.
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (change == AudioManager.AUDIOFOCUS_LOSS) hasFocus = false
                // Only a short interruption (a call, a voice note) resumes by itself.
                pausedForFocus = change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT && MediaBridge.state?.playing == true
                if (MediaBridge.state?.playing == true) MediaBridge.emit("pause")
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (pausedForFocus) MediaBridge.emit("play")
                pausedForFocus = false
            }
        }
    }

    /** Headphones unplugged / Bluetooth dropped: pause instead of blasting the speaker. */
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) MediaBridge.emit("pause")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        session = MediaSession(this, "FetchNet").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = MediaBridge.emit("play")
                override fun onPause() = MediaBridge.emit("pause")
                override fun onSkipToNext() = MediaBridge.emit("next")
                override fun onSkipToPrevious() = MediaBridge.emit("previous")
                override fun onSeekTo(pos: Long) = MediaBridge.emit("seek", pos)
                override fun onStop() = MediaBridge.emit("stop")
            })
            setSessionActivity(openAppIntent())
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY_PAUSE -> MediaBridge.emit(if (MediaBridge.state?.playing == true) "pause" else "play")
            ACTION_NEXT -> MediaBridge.emit("next")
            ACTION_PREVIOUS -> MediaBridge.emit("previous")
        }
        render()
        return START_NOT_STICKY
    }

    /** Shows [MediaBridge.state] in the session and the notification. */
    fun render() {
        val s = MediaBridge.state
        if (s == null) {
            // startForegroundService() still needs a startForeground() call.
            if (!foreground) startAsForeground(placeholder())
            stopNow()
            return
        }
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, s.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, s.artist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, s.durationMs)
                .apply { if (s.art != null) putBitmap(MediaMetadata.METADATA_KEY_ART, s.art) }
                .build()
        )
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP
        if (s.canNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        if (s.canPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (s.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    s.positionMs,
                    if (s.playing) s.speed else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .build()
        )
        if (s.playing) {
            requestFocus()
            registerNoisy()
        } else {
            unregisterNoisy()
        }
        startAsForeground(build(s))
    }

    private fun startAsForeground(notification: Notification) {
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0,
            )
            foreground = true
        } catch (_: Exception) {
            // Background start limits: keep the notification up anyway.
            getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification)
        }
    }

    fun stopNow() {
        unregisterNoisy()
        abandonFocus()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
        stopSelf()
    }

    private fun channel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Controls for the YouTube player"
                setShowBadge(false)
            }
        )
    }

    @Suppress("DEPRECATION")
    private fun builder(): Notification.Builder {
        channel()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
    }

    private fun placeholder(): Notification = builder()
        .setSmallIcon(R.drawable.ic_stat_fetchnet)
        .setContentTitle("FetchNet")
        .build()

    private fun build(s: MediaState): Notification {
        val b = builder()
            .setSmallIcon(R.drawable.ic_stat_fetchnet)
            .setColor(0xFF6D28D9.toInt())
            .setContentTitle(s.title)
            .setContentText(s.artist)
            .setLargeIcon(s.art)
            .setContentIntent(openAppIntent())
            .setOngoing(s.playing)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
        val compact = mutableListOf<Int>()
        var index = 0
        if (s.canPrevious) {
            b.addAction(action(android.R.drawable.ic_media_previous, "Previous", ACTION_PREVIOUS, 1))
            compact += index++
        }
        b.addAction(
            if (s.playing) action(android.R.drawable.ic_media_pause, "Pause", ACTION_PLAY_PAUSE, 2)
            else action(android.R.drawable.ic_media_play, "Play", ACTION_PLAY_PAUSE, 2)
        )
        compact += index++
        if (s.canNext) {
            b.addAction(action(android.R.drawable.ic_media_next, "Next", ACTION_NEXT, 3))
            compact += index
        }
        b.setStyle(
            Notification.MediaStyle()
                .setMediaSession(session.sessionToken)
                .setShowActionsInCompactView(*compact.toIntArray())
        )
        return b.build()
    }

    private fun action(icon: Int, title: String, action: String, code: Int): Notification.Action {
        val intent = PendingIntent.getService(
            this, code, Intent(this, MediaPlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(icon, title, intent).build()
    }

    private fun openAppIntent(): PendingIntent {
        val intent = (packageManager.getLaunchIntentForPackage(packageName) ?: Intent())
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(this, 7, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun requestFocus() {
        if (hasFocus) return
        hasFocus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
                .also { focusRequest = it }
            audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        if (!hasFocus) return
        hasFocus = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        ContextCompat.registerReceiver(
            this, noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        runCatching { unregisterReceiver(noisy) }
        noisyRegistered = false
    }

    /** App swiped away from Recents: the player is gone, so is the notification. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        MediaBridge.state = null
        stopNow()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        unregisterNoisy()
        abandonFocus()
        session.release()
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "fetchnet_playback"
        private const val NOTIFICATION_ID = 39001
        private const val ACTION_PLAY_PAUSE = "com.fetchnet.media.PLAY_PAUSE"
        private const val ACTION_NEXT = "com.fetchnet.media.NEXT"
        private const val ACTION_PREVIOUS = "com.fetchnet.media.PREVIOUS"

        @Volatile var instance: MediaPlaybackService? = null
            private set
    }
}
