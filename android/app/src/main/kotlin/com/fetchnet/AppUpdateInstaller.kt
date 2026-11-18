package com.fetchnet

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Installs a downloaded FetchNet update through Android's package installer
 * (session API), and reports how it went:
 *
 * - `pending_user`: Android's confirmation screen is open (always shown for
 *   apps installed outside a store);
 * - `success`: installed (Android replaces this process right after);
 * - `failure` + `message`: refused (another signature, a lower version
 *   code, not enough space, ...);
 * - `cancelled`: the user backed out of the confirmation.
 *
 * Installing apps needs "Install unknown apps" for FetchNet (Android 8+):
 * [canInstall] tells, [openPermissionSettings] opens that page.
 */
class AppUpdateInstaller(private val activity: Activity, private val emit: (Map<String, Any?>) -> Unit) {

    companion object {
        private const val ACTION_STATUS = "com.fetchnet.action.UPDATE_INSTALL_STATUS"
    }

    private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            when (status) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    if (confirm == null) {
                        emit(mapOf("status" to "failure", "message" to "Android didn't open its installer."))
                        return
                    }
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        activity.startActivity(confirm)
                        emit(mapOf("status" to "pending_user"))
                    } catch (e: Exception) {
                        emit(mapOf("status" to "failure", "message" to (e.message ?: "Android didn't open its installer.")))
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> emit(mapOf("status" to "success"))
                PackageInstaller.STATUS_FAILURE_ABORTED -> emit(mapOf("status" to "cancelled"))
                else -> emit(mapOf("status" to "failure", "message" to describe(status, message)))
            }
        }
    }

    fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    fun openPermissionSettings() {
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
        activity.startActivity(intent)
    }

    /** Copies [path] into an install session and commits it. Call off the main thread. */
    fun install(path: String) {
        register()
        val file = File(path)
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(activity.packageName)
            setSize(file.length())
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("fetchnet.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                val callback = PendingIntent.getBroadcast(
                    activity,
                    sessionId,
                    Intent(ACTION_STATUS).setPackage(activity.packageName),
                    flags,
                )
                session.commit(callback.intentSender)
            }
        } catch (e: Exception) {
            try {
                installer.abandonSession(sessionId)
            } catch (_: Exception) {
            }
            throw e
        }
    }

    private fun register() {
        if (registered) return
        ContextCompat.registerReceiver(
            activity.applicationContext,
            receiver,
            IntentFilter(ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        registered = true
    }

    private fun describe(status: Int, message: String?): String = when (status) {
        PackageInstaller.STATUS_FAILURE_CONFLICT ->
            "It conflicts with the installed FetchNet (signed with another key, or an older build). Install it from the website."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "This update doesn't run on this device."
        PackageInstaller.STATUS_FAILURE_STORAGE -> "There isn't enough storage space to install it."
        PackageInstaller.STATUS_FAILURE_INVALID -> "The downloaded update is damaged."
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android blocked the installation."
        else -> message?.takeIf { it.isNotBlank() } ?: "Android didn't install the update."
    }
}
