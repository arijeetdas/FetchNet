package com.fetchnet

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.core.graphics.drawable.toBitmap
import java.io.File

/**
 * Chrome-style per-download notifications:
 *  - while running: a live, ongoing notification (an Android 16 "Live Update"
 *    with a status-bar chip where supported) with progress and Cancel;
 *  - when done: the same notification turns into "Download complete" with
 *    Open / Share, or "Download failed".
 *
 * One live notification at a time is the foreground-service notification
 * ([DownloadService]); when that download finishes the service re-pins to
 * another active one so the finished notification can change in place.
 */
object DownloadNotifier {
    private const val CHANNEL_ACTIVE = "fetchnet_active_downloads"
    private const val CHANNEL_DONE = "fetchnet_finished_downloads"
    private const val LEGACY_CHANNEL = "fetchnet_downloads"

    const val ACTION_CANCEL = "com.fetchnet.action.CANCEL_DOWNLOAD"
    const val EXTRA_TASK_ID = "taskId"
    const val EXTRA_OPEN_TAB = "com.fetchnet.extra.OPEN_TAB"

    private val main = Handler(Looper.getMainLooper())

    private data class Active(
        val id: String,
        val notificationId: Int,
        var fileName: String,
        var text: String,
        var detail: String,
        var progress: Int,
    )

    private val active = LinkedHashMap<String, Active>()

    /** Notification id the foreground service is currently attached to. */
    @Volatile var pinnedId: Int? = null
        private set

    /** Set by MainActivity: forwards notification actions to Dart. */
    @Volatile var onAction: ((action: String, taskId: String?) -> Unit)? = null

    fun notificationIdFor(taskId: String) = 41000 + (taskId.hashCode() and 0xFFFFF)

    private const val BRAND_VIOLET = 0xFF7C3AED.toInt()

    @Volatile private var appIconBitmap: Bitmap? = null

    /**
     * The launcher icon as a bitmap, in the device's own icon shape (adaptive
     * icons are drawn through the launcher mask, so it matches the home screen).
     */
    private fun appIcon(context: Context): Bitmap {
        appIconBitmap?.let { return it }
        val size = (context.resources.displayMetrics.density * 64).toInt().coerceIn(96, 256)
        val bitmap = try {
            context.packageManager.getApplicationIcon(context.packageName).toBitmap(size, size, Bitmap.Config.ARGB_8888)
        } catch (_: Exception) {
            ContextCompat.getDrawable(context, R.mipmap.ic_launcher)!!.toBitmap(size, size, Bitmap.Config.ARGB_8888)
        }
        appIconBitmap = bitmap
        return bitmap
    }

    private fun channels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.deleteNotificationChannel(LEGACY_CHANNEL)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ACTIVE, "Active downloads", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Live progress of downloads in progress"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Finished downloads", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Shown when a download completes or fails"
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    // ───────────────────────── live ─────────────────────────

    fun progress(context: Context, id: String, fileName: String, text: String, detail: String, progress: Int) {
        channels(context)
        val entry = active.getOrPut(id) {
            Active(id, notificationIdFor(id), fileName, text, detail, progress)
        }
        entry.fileName = fileName
        entry.text = text
        entry.detail = detail
        entry.progress = progress
        val notification = buildLive(context, entry)
        val service = DownloadService.instance
        when {
            pinnedId == null && service != null -> {
                pinnedId = entry.notificationId
                service.pin(entry.notificationId, notification)
            }
            pinnedId == null -> {
                pinnedId = entry.notificationId
                DownloadService.start(context)
            }
            pinnedId == entry.notificationId && service != null -> service.pin(entry.notificationId, notification)
            else -> post(context, entry.notificationId, notification)
        }
        // Make sure it is visible right away even before the service starts.
        if (service == null) post(context, entry.notificationId, notification)
    }

    /** Called by the service when it starts: the notification to attach to. */
    fun pinnedNotification(context: Context): Pair<Int, android.app.Notification>? {
        val id = pinnedId ?: return null
        val entry = active.values.firstOrNull { it.notificationId == id } ?: return null
        return id to buildLive(context, entry)
    }

    private fun buildLive(context: Context, e: Active): android.app.Notification {
        val indeterminate = e.progress < 0
        val builder = NotificationCompat.Builder(context, CHANNEL_ACTIVE)
            .setSmallIcon(R.drawable.ic_stat_fetchnet)
            .setColor(0xFF6D28D9.toInt())
            .setContentTitle(e.fileName)
            .setContentText(e.text)
            .setSubText(e.detail.ifBlank { null })
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setContentIntent(openAppIntent(context, e.notificationId))
            .addAction(R.drawable.ic_action_cancel, "Cancel", cancelIntent(context, e.id, e.notificationId))
            // Live (promoted) notifications are drawn with the monochrome small
            // icon on some skins (e.g. OriginOS); the large icon brings back
            // the real app icon, like the finished notification has.
            .setLargeIcon(appIcon(context))
            // Android 16+: promote to a Live Update with a status-bar chip.
            .setRequestPromotedOngoing(true)
            .setShortCriticalText(if (indeterminate) "…" else "${e.progress}%")
        if (Build.VERSION.SDK_INT >= 36) {
            builder.setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgressIndeterminate(indeterminate)
                    // One brand-violet segment, otherwise the system paints
                    // the bar in its own accent colour.
                    .setProgressSegments(listOf(NotificationCompat.ProgressStyle.Segment(100).setColor(BRAND_VIOLET)))
                    .setProgress(e.progress.coerceIn(0, 100))
                    .setStyledByProgress(true)
                    // The full-colour app icon rides the bar.
                    .setProgressTrackerIcon(IconCompat.createWithBitmap(appIcon(context)))
            )
        } else {
            builder.setProgress(100, e.progress.coerceIn(0, 100), indeterminate)
        }
        return builder.build()
    }

    // ───────────────────────── finished ─────────────────────────

    fun complete(context: Context, id: String, fileName: String, path: String, sizeText: String) {
        channels(context)
        val notificationId = active[id]?.notificationId ?: notificationIdFor(id)
        val file = File(path)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        MediaScannerConnection.scanFile(context.applicationContext, arrayOf(path), arrayOf(mime)) { _, uri ->
            main.post {
                val builder = NotificationCompat.Builder(context, CHANNEL_DONE)
                    .setSmallIcon(R.drawable.ic_stat_done)
                    .setColor(0xFF6D28D9.toInt())
                    .setContentTitle(fileName)
                    .setContentText(listOf("Download complete", sizeText).filter { it.isNotBlank() }.joinToString(" · "))
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .setWhen(System.currentTimeMillis())
                    .setShowWhen(true)
                if (uri != null) {
                    val open = PendingIntent.getActivity(
                        context, notificationId, viewIntent(uri, mime),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    val share = PendingIntent.getActivity(
                        context, notificationId + 1, shareIntent(uri, mime),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    builder.setContentIntent(open)
                        .addAction(R.drawable.ic_stat_done, "Open", open)
                        .addAction(R.drawable.ic_stat_fetchnet, "Share", share)
                } else {
                    builder.setContentIntent(openAppIntent(context, notificationId))
                }
                finish(context, id, notificationId, builder.build())
            }
        }
    }

    fun failed(context: Context, id: String, fileName: String, reason: String) {
        channels(context)
        val notificationId = active[id]?.notificationId ?: notificationIdFor(id)
        val notification = NotificationCompat.Builder(context, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_stat_fetchnet)
            .setColor(0xFFB3261E.toInt())
            .setContentTitle(fileName)
            .setContentText("Download failed")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Download failed · $reason"))
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent(context, notificationId))
            .build()
        finish(context, id, notificationId, notification)
    }

    fun cancelled(context: Context, id: String) {
        val notificationId = active[id]?.notificationId ?: notificationIdFor(id)
        finish(context, id, notificationId, null)
    }

    /** Stops tracking [id]; re-pins the service if needed, then shows [final] in place. */
    private fun finish(context: Context, id: String, notificationId: Int, final: android.app.Notification?) {
        active.remove(id)
        val service = DownloadService.instance
        if (pinnedId == notificationId) {
            val next = active.values.firstOrNull()
            if (next != null) {
                pinnedId = next.notificationId
                service?.pin(next.notificationId, buildLive(context, next))
            } else {
                pinnedId = null
                service?.release()
            }
        }
        val nm = NotificationManagerCompat.from(context)
        if (final == null) {
            nm.cancel(notificationId)
        } else {
            post(context, notificationId, final)
        }
    }

    /** App closed: drop every live notification. */
    fun clearAll(context: Context) {
        val nm = NotificationManagerCompat.from(context)
        active.values.forEach { nm.cancel(it.notificationId) }
        active.clear()
        pinnedId = null
        DownloadService.instance?.release()
    }

    private fun post(context: Context, id: Int, notification: android.app.Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (_: SecurityException) {
            // Notification permission denied: nothing to show.
        }
    }

    // ───────────────────────── intents ─────────────────────────

    private fun openAppIntent(context: Context, requestCode: Int): PendingIntent {
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent())
            .putExtra(EXTRA_OPEN_TAB, "downloads")
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun cancelIntent(context: Context, taskId: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, NotificationActionReceiver::class.java)
            .setAction(ACTION_CANCEL)
            .putExtra(EXTRA_TASK_ID, taskId)
        return PendingIntent.getBroadcast(
            context, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun viewIntent(uri: Uri, mime: String) = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, mime)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun shareIntent(uri: Uri, mime: String) = Intent.createChooser(
        Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        "Share",
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun handleCancelAction(context: Context, taskId: String) {
        active[taskId]?.let {
            it.text = "Cancelling…"
            progress(context, it.id, it.fileName, it.text, it.detail, -1)
        }
        onAction?.invoke("cancel", taskId)
    }
}

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == DownloadNotifier.ACTION_CANCEL) {
            val id = intent.getStringExtra(DownloadNotifier.EXTRA_TASK_ID) ?: return
            DownloadNotifier.handleCancelAction(context.applicationContext, id)
        }
    }
}
