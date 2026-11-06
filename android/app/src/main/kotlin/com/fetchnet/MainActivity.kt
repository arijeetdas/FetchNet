package com.fetchnet

import android.Manifest
import android.app.PictureInPictureParams
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Rational
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
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

    private companion object {
        const val TAG = "FetchNet"
    }

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

    // ───── Picture-in-picture (YouTube player) ─────
    private var pipEvents: EventChannel.EventSink? = null
    private var autoPip = false
    private var pipAspect = Rational(16, 9)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSharedText = extractSharedText(intent)
        tabAction(intent)?.let { pendingLaunchAction = it }
    }

    /** `open_downloads` / `open_history` / `open_settings` from a notification or an app shortcut. */
    private fun tabAction(intent: Intent?): String? {
        val tab = intent?.getStringExtra(DownloadNotifier.EXTRA_OPEN_TAB) ?: return null
        return if (tab in setOf("downloads", "history", "settings")) "open_$tab" else null
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = tabAction(intent)
        if (action != null) {
            val sink = actionEvents
            if (sink != null) sink.success(mapOf("action" to action)) else pendingLaunchAction = action
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
                        Log.e(TAG, "engine init failed", e)
                        postResult { result.error("init_failed", describe(e), null) }
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
                        Log.e(TAG, "engine update failed", e)
                        postResult { result.error("update_failed", describe(e), null) }
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
                        "pubspecVersionName" to BuildConfig.PUBSPEC_VERSION_NAME,
                        "pubspecBuildNumber" to BuildConfig.PUBSPEC_BUILD_NUMBER,
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

                "shareFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("share_failed", "No file was given.", null)
                    } else {
                        shareFile(path, call.argument<String>("title")) { error ->
                            postResult {
                                if (error == null) result.success(true) else result.error("share_failed", error, null)
                            }
                        }
                    }
                }

                "shareText" -> {
                    val text = call.argument<String>("text")
                    if (text.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                            call.argument<String>("subject")?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                        }
                        result.success(
                            runCatching {
                                startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            }.isSuccess,
                        )
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

                "pipSupported" -> result.success(pipSupported())

                // Shrinks the app into a floating video window.
                "enterPip" -> {
                    pipAspect = aspect(call.argument<Int>("width"), call.argument<Int>("height"))
                    result.success(enterPip())
                }

                // Enter PiP by itself when the user leaves the app (video playing).
                "setAutoPip" -> {
                    autoPip = call.argument<Boolean>("enabled") == true
                    pipAspect = aspect(call.argument<Int>("width"), call.argument<Int>("height"))
                    if (Build.VERSION.SDK_INT >= 31 && pipSupported()) {
                        runCatching { setPictureInPictureParams(pipParams()) }
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

        // ───── Media notification (YouTube player) ─────
        MethodChannel(messenger, "fetchnet/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val bytes = call.argument<ByteArray>("art")
                    val keepArt = call.argument<Boolean>("keepArt") == true
                    val art = when {
                        bytes != null -> runCatching { android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
                        keepArt -> MediaBridge.state?.art
                        else -> null
                    }
                    MediaBridge.update(
                        applicationContext,
                        MediaState(
                            title = call.argument<String>("title") ?: "",
                            artist = call.argument<String>("artist") ?: "",
                            art = art,
                            durationMs = (call.argument<Number>("durationMs") ?: 0).toLong(),
                            positionMs = (call.argument<Number>("positionMs") ?: 0).toLong(),
                            playing = call.argument<Boolean>("playing") == true,
                            speed = (call.argument<Number>("speed") ?: 1.0).toFloat(),
                            canPrevious = call.argument<Boolean>("canPrevious") == true,
                            canNext = call.argument<Boolean>("canNext") == true,
                        ),
                    )
                    result.success(null)
                }

                "stop" -> {
                    MediaBridge.stop()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "fetchnet/media/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                MediaBridge.events = events
            }

            override fun onCancel(arguments: Any?) {
                MediaBridge.events = null
            }
        })

        EventChannel(messenger, "fetchnet/pip").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pipEvents = events
            }

            override fun onCancel(arguments: Any?) {
                pipEvents = null
            }
        })

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

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= 26 && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** Android only accepts ratios between 1:2.39 and 2.39:1. */
    private fun aspect(width: Int?, height: Int?): Rational {
        if (width == null || height == null || width <= 0 || height <= 0) return Rational(16, 9)
        val r = width.toDouble() / height
        return when {
            r > 2.39 -> Rational(239, 100)
            r < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(width, height)
        }
    }

    @androidx.annotation.RequiresApi(26)
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipAspect)
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setAutoEnterEnabled(autoPip)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < 26 || !pipSupported()) return false
        return runCatching { enterPictureInPictureMode(pipParams()) }.getOrDefault(false)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters by itself (setAutoEnterEnabled).
        if (autoPip && Build.VERSION.SDK_INT in 26..30) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipEvents?.success(isInPictureInPictureMode)
    }

    override fun onDestroy() {
        if (isFinishing) {
            // The player lives in this engine: its controls go with it.
            MediaBridge.events = null
            MediaBridge.stop()
            DownloadNotifier.onAction = null
            DownloadNotifier.clearAll(applicationContext)
        }
        super.onDestroy()
    }

    private fun postResult(block: () -> Unit) = mainHandler.post(block)

    /** "Type: message ← CauseType: message …" so failures are never a bare class name. */
    private fun describe(e: Throwable): String =
        generateSequence(e) { it.cause }.take(4).joinToString("  ←  ") { t ->
            listOfNotNull(t.javaClass.name, t.message?.takeIf { it.isNotBlank() }).joinToString(": ")
        }

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
            // youtubedl-android passes --no-cache-dir unless it gets a cache
            // dir. Without one, every run re-downloads YouTube's player script
            // and re-solves its JS challenge in QuickJS: the slowest part of a
            // lookup on a phone. (Options go before our args, ahead of "--".)
            if ("--cache-dir" !in args && "--no-cache-dir" !in args) {
                val cache = File(cacheDir, "yt-dlp").apply { mkdirs() }
                request.addOption("--cache-dir", cache.absolutePath)
            }
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
            Log.e(TAG, "yt-dlp run failed", e)
            mapOf("exitCode" to -1, "out" to "", "err" to describe(e))
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

    /**
     * System share sheet for a downloaded file. Uses FetchNet's FileProvider
     * (works for every file type); falls back to the file's MediaStore URI.
     * Calls [done] with `null` on success or a human readable reason.
     */
    private fun shareFile(path: String, title: String?, done: (String?) -> Unit) {
        val file = File(path)
        if (!file.exists()) {
            done("The file is no longer on this device.")
            return
        }
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        val providerUri = runCatching {
            FileProvider.getUriForFile(applicationContext, "$packageName.share", file)
        }.onFailure { Log.w("FetchNet", "FileProvider share failed for $path", it) }.getOrNull()
        if (providerUri != null) {
            done(startShare(providerUri, mime, file.name, title))
            return
        }
        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), arrayOf(mime)) { _, uri: Uri? ->
            mainHandler.post {
                done(if (uri == null) "Android couldn't index this file for sharing." else startShare(uri, mime, file.name, title))
            }
        }
    }

    private fun startShare(uri: Uri, mime: String, fileName: String, title: String?): String? {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!title.isNullOrBlank()) putExtra(Intent.EXTRA_TITLE, title)
            // Lets the share sheet show a preview and grants read access to the target.
            clipData = ClipData.newRawUri(fileName, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            val chooser = Intent.createChooser(send, title ?: fileName).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            null
        } catch (e: ActivityNotFoundException) {
            "No app on this device can receive this file."
        } catch (e: Throwable) {
            Log.w("FetchNet", "Share failed", e)
            describe(e)
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
