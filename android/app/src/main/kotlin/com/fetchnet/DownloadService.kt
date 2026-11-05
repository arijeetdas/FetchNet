package com.fetchnet

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive while downloads run. It has no notification of its
 * own: it attaches to one of the live download notifications managed by
 * [DownloadNotifier] and moves to another when that download finishes.
 */
class DownloadService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pinned = DownloadNotifier.pinnedNotification(this)
        if (pinned == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        pin(pinned.first, pinned.second)
        return START_NOT_STICKY
    }

    fun pin(notificationId: Int, notification: Notification) {
        try {
            ServiceCompat.startForeground(
                this,
                notificationId,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (_: Exception) {
            // Not allowed right now (background start limits); downloads still
            // run while the process is alive.
        }
    }

    /** Detaches (keeps) the current notification and stops the service. */
    fun release() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        stopSelf()
    }

    // Android 15+: data-sync services get a time limit.
    override fun onTimeout(startId: Int, fgsType: Int) {
        release()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: DownloadService? = null
            private set

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
