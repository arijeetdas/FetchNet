package com.fetchnet

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newCachedThreadPool()

    @Volatile private var engineReady = false
    private var engineEvents: EventChannel.EventSink? = null
    private var shareEvents: EventChannel.EventSink? = null
    private var pendingSharedText: String? = null
    private var pendingLaunchAction: String? = null
    private var actionEvents: EventChannel.EventSink? = null
    private val pendingPermissions = mutableMapOf<Int, MethodChannel.Result>()
    private var nextPermissionCode = 7100

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSharedText = extractSharedText(intent)
        if (intent?.getStringExtra(DownloadNotifier.EXTRA_OPEN_TAB) == "downloads") pendingLaunchAction = "open_downloads"
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(DownloadNotifier.EXTRA_OPEN_TAB) == "downloads") {
            val sink = actionEvents
            if (sink != null) sink.success(mapOf("action" to "open_downloads")) else pendingLaunchAction = "open_downloads"
            return
        }
        val text = extractSharedText(intent) ?: return
        val sink = shareEvents
        if (sink != null) sink.success(text) else pendingSharedText = text
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ───── yt-dlp engine ─────
        MethodChannel(messenger, "fetchnet/engine").setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> executor.execute {
                    try {
                        ensureEngine()
                        val version = YoutubeDL.getInstance().version(applicationContext)
                        postResult { result.success(mapOf("version" to version)) }
                    } catch (e: Throwable) {
                        postResult { result.error("init_failed", e.message ?: e.toString(), null) }
                    }
                }

                "update" -> executor.execute {
                    try {
                        ensureEngine()
                        val channel = when (call.argument<String>("channel")) {
                            "nightly" -> YoutubeDL.UpdateChannel.NIGHTLY
                            else -> YoutubeDL.UpdateChannel.STABLE
                        }
                        val status = YoutubeDL.getInstance().updateYoutubeDL(applicationContext, channel)
                        val version = YoutubeDL.getInstance().version(applicationContext)
                        postResult {
                            result.success(mapOf("status" to (status?.name ?: "UNKNOWN"), "version" to version))
                        }
                    } catch (e: Throwable) {
                        postResult { result.error("update_failed", e.message ?: e.toString(), null) }
                    }
                }

                // Runs yt-dlp to completion and returns its output (used for -J).
                "run" -> {
                    val id = call.argument<String>("id") ?: ""
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    executor.execute {
                        val response = runYtDlp(id, args, onLine = null)
                        postResult { result.success(response) }
                    }
                }

                // Starts yt-dlp and streams every output line through the event channel.
                "start" -> {
                    val id = call.argument<String>("id") ?: ""
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    result.success(null)
                    executor.execute {
                        // stderr is merged so post-processing progress (printed
                        // there) reaches the line callback too.
                        val response = runYtDlp(id, args, redirectErrorStream = true) { line ->
                            mainHandler.post {
                                engineEvents?.success(mapOf("id" to id, "type" to "line", "line" to line))
                            }
                        }
                        mainHandler.post {
                            engineEvents?.success(response + mapOf("id" to id, "type" to "exit"))
                        }
                    }
                }

                "cancel" -> {
                    val id = call.argument<String>("id") ?: ""
                    val killed = runCatching { YoutubeDL.getInstance().destroyProcessById(id) }.getOrDefault(false)
                    result.success(killed)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "fetchnet/engine/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                engineEvents = events
            }

            override fun onCancel(arguments: Any?) {
                engineEvents = null
            }
        })

        // ───── Platform helpers ─────
        MethodChannel(messenger, "fetchnet/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceEnvironment" -> result.success(
                    mapOf(
                        "isChromeOS" to isRunningOnChromeOS(),
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                        "installedApkType" to getInstalledApkType(),
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "manufacturer" to (Build.MANUFACTURER ?: ""),
                        "model" to (Build.MODEL ?: ""),
                    )
                )

                "getDownloadDirectory" -> {
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "FetchNet",
                    )
                    val ok = dir.isDirectory || dir.mkdirs()
                    result.success(mapOf("path" to dir.absolutePath, "exists" to (ok && dir.isDirectory)))
                }

                "needsLegacyStoragePermission" -> {
                    val needs = Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q &&
                        ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED
                    result.success(needs)
                }

                // "storage" (Android 10 and older) or "notifications" (Android 13+).
                "requestPermission" -> {
                    val permission = when (call.argument<String>("name")) {
                        "storage" -> if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                            Manifest.permission.WRITE_EXTERNAL_STORAGE
                        } else null
                        "notifications" -> if (Build.VERSION.SDK_INT >= 33) {
                            Manifest.permission.POST_NOTIFICATIONS
                        } else null
                        else -> null
                    }
                    if (permission == null ||
                        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        val code = nextPermissionCode++
                        pendingPermissions[code] = result
                        ActivityCompat.requestPermissions(this, arrayOf(permission), code)
                    }
                }

                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(false)
                    } else {
                        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
                        result.success(true)
                    }
                }

                "openFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(false)
                    } else {
                        openFile(path) { opened -> postResult { result.success(opened) } }
                    }
                }

                "consumeSharedText" -> {
                    val text = pendingSharedText
                    pendingSharedText = null
                    result.success(text)
                }

                // Per-download notifications: state = progress | complete | failed | cancelled.
                "downloadNotification" -> {
                    val id = call.argument<String>("id") ?: ""
                    val fileName = call.argument<String>("fileName") ?: "Download"
                    when (call.argument<String>("state")) {
                        "progress" -> DownloadNotifier.progress(
                            applicationContext, id, fileName,
                            call.argument<String>("text") ?: "",
                            call.argument<String>("detail") ?: "",
                            call.argument<Int>("progress") ?: -1,
                        )
                        "complete" -> DownloadNotifier.complete(
                            applicationContext, id, fileName,
                            call.argument<String>("path") ?: "",
                            call.argument<String>("size") ?: "",
                        )
                        "failed" -> DownloadNotifier.failed(
                            applicationContext, id, fileName, call.argument<String>("text") ?: "",
                        )
                        else -> DownloadNotifier.cancelled(applicationContext, id)
                    }
                    result.success(null)
                }

                "consumeLaunchAction" -> {
                    val action = pendingLaunchAction
                    pendingLaunchAction = null
                    result.success(action)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "fetchnet/notification_actions").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                actionEvents = events
            }

            override fun onCancel(arguments: Any?) {
                actionEvents = null
            }
        })
        DownloadNotifier.onAction = { action, taskId ->
            mainHandler.post { actionEvents?.success(mapOf("action" to action, "id" to taskId)) }
        }

        EventChannel(messenger, "fetchnet/share").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                shareEvents = events
            }

            override fun onCancel(arguments: Any?) {
                shareEvents = null
            }
        })
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val pending = pendingPermissions.remove(requestCode) ?: return
        pending.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
    }

    override fun onDestroy() {
        if (isFinishing) {
            DownloadNotifier.onAction = null
            DownloadNotifier.clearAll(applicationContext)
        }
        super.onDestroy()
    }

    private fun postResult(block: () -> Unit) = mainHandler.post(block)

    @Synchronized
    private fun ensureEngine() {
        if (engineReady) return
        YoutubeDL.getInstance().init(applicationContext)
        FFmpeg.getInstance().init(applicationContext)
        engineReady = true
    }

    /**
     * Runs yt-dlp with [args]. The exit code is `-2` when the run was cancelled
     * and `-1` when yt-dlp could not be started at all.
     */
    private fun runYtDlp(
        id: String,
        args: List<String>,
        redirectErrorStream: Boolean = false,
        onLine: ((String) -> Unit)?,
    ): Map<String, Any?> {
        // Last output lines: with merged streams yt-dlp's errors arrive here.
        val tail = ArrayDeque<String>()
        return try {
            ensureEngine()
            val request = YoutubeDLRequest(emptyList<String>())
            request.addCommands(args)
            val response = YoutubeDL.getInstance().execute(request, id.ifEmpty { null }, redirectErrorStream) { _, _, line ->
                synchronized(tail) {
                    tail.addLast(line)
                    if (tail.size > 40) tail.removeFirst()
                }
                onLine?.invoke(line)
            }
            mapOf("exitCode" to response.exitCode, "out" to response.out, "err" to response.err)
        } catch (e: YoutubeDL.CanceledException) {
            mapOf("exitCode" to -2, "out" to "", "err" to "Cancelled")
        } catch (e: YoutubeDLException) {
            val message = e.message?.takeIf { it.isNotBlank() } ?: synchronized(tail) { tail.joinToString("\n") }
            mapOf("exitCode" to 1, "out" to "", "err" to message)
        } catch (e: InterruptedException) {
            mapOf("exitCode" to -2, "out" to "", "err" to "Cancelled")
        } catch (e: Throwable) {
            mapOf("exitCode" to -1, "out" to "", "err" to (e.message ?: e.toString()))
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }?.takeIf { it.isNotBlank() }
    }

    /** Opens [path] in the user's default app through its MediaStore content URI. */
    private fun openFile(path: String, done: (Boolean) -> Unit) {
        val file = File(path)
        if (!file.exists()) {
            done(false)
            return
        }
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), arrayOf(mime)) { _, uri: Uri? ->
            mainHandler.post {
                if (uri == null) {
                    done(false)
                    return@post
                }
                val view = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                try {
                    startActivity(Intent.createChooser(view, "Open with").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    done(true)
                } catch (e: ActivityNotFoundException) {
                    done(false)
                }
            }
        }
    }

    private fun isRunningOnChromeOS(): Boolean {
        val pm = packageManager
        if (runCatching { pm.hasSystemFeature("org.chromium.arc") }.getOrDefault(false)) return true
        if (runCatching { pm.hasSystemFeature("org.chromium.arc.device_management") }.getOrDefault(false)) return true
        val device = Build.DEVICE.orEmpty()
        return device.matches(Regex(".+_cheets|cheets_.+"))
    }

    /** `universal`, `arm64-v8a`, `armeabi-v7a`, `x86_64` or `x86`, from the installed APK's native libs. */
    private fun getInstalledApkType(): String {
        try {
            val apkPath = applicationInfo.sourceDir ?: return "universal"
            java.util.zip.ZipFile(apkPath).use { zip ->
                val abis = mutableSetOf<String>()
                // Flutter's own engine library is present in every flavour, so it
                // tells which ABIs this APK was built for (the yt-dlp libs ship all four).
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement().name
                    if (name.startsWith("lib/") && name.endsWith("/libflutter.so")) {
                        abis.add(name.split("/")[1])
                    }
                }
                val standard = abis.filter { it in setOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64") }
                if (standard.size > 1) return "universal"
                if (standard.size == 1) return standard.first()
            }
        } catch (_: Exception) {
        }
        return "universal"
    }
}
