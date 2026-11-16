package com.fetchnet

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Runs gallery-dl (images, galleries, posts) on the Python 3.12 that
 * youtubedl-android unpacks for yt-dlp, so nothing extra ships in the APK.
 *
 * The environment mirrors the one youtubedl-android gives yt-dlp
 * (`YoutubeDL.init`): its `packages/python/usr` as PYTHONHOME and HOME, the
 * Python / FFmpeg / aria2c libraries on LD_LIBRARY_PATH, and its CA bundle.
 * gallery-dl's own files (downloaded from PyPI by the Dart side) come first on
 * PYTHONPATH, followed by the yt-dlp zipapp so gallery-dl can hand videos to
 * yt-dlp.
 */
class GalleryDl(private val context: Context) {

    private val processes = ConcurrentHashMap<String, Process>()
    private val cancelled: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private val base get() = File(context.noBackupFilesDir, "youtubedl-android")
    private val packages get() = File(base, "packages")
    private val pythonHome get() = File(packages, "python/usr")

    /**
     * Runs `python -m gallery_dl args` with [site] (the unpacked packages) on
     * PYTHONPATH. [onLine] receives every output line (stdout and stderr) as
     * it is printed. The exit code is `-2` when the run was cancelled and `-1`
     * when Python could not start.
     */
    fun run(id: String, site: String, args: List<String>, onLine: ((String) -> Unit)?): Map<String, Any?> {
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val python = File(nativeDir, "libpython.so")
        if (!python.exists() || !pythonHome.exists()) {
            return mapOf("exitCode" to -1, "out" to "", "err" to "Python isn't ready yet. Wait for yt-dlp to finish starting.")
        }
        val command = mutableListOf(python.absolutePath, "-m", "gallery_dl")
        val ffmpeg = File(nativeDir, "libffmpeg.so")
        if (ffmpeg.exists()) {
            // Videos gallery-dl hands to yt-dlp may need merging.
            command += listOf("-o", "downloader.ytdl.raw-options={\"ffmpeg_location\": ${JSONObject.quote(ffmpeg.absolutePath)}}")
        }
        command += args

        val builder = ProcessBuilder(command).directory(context.cacheDir)
        val env = builder.environment()
        env["LD_LIBRARY_PATH"] = listOf("python", "ffmpeg", "aria2c")
            .joinToString(":") { File(packages, "$it/usr/lib").absolutePath }
        env["SSL_CERT_FILE"] = File(pythonHome, "etc/tls/cert.pem").absolutePath
        env["PYTHONHOME"] = pythonHome.absolutePath
        env["HOME"] = pythonHome.absolutePath
        env["PATH"] = "${System.getenv("PATH")}:$nativeDir"
        env["TMPDIR"] = context.cacheDir.absolutePath
        env["PYTHONPATH"] = listOf(File(site), File(base, "yt-dlp/yt-dlp"))
            .filter { it.exists() }
            .joinToString(":") { it.absolutePath }
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"

        val process = try {
            builder.start()
        } catch (e: Exception) {
            return mapOf("exitCode" to -1, "out" to "", "err" to "Couldn't start Python: ${e.message}")
        }
        processes[id] = process
        val out = StringBuilder()
        val err = StringBuilder()
        val outReader = Thread {
            process.inputStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                synchronized(out) { out.append(line).append('\n') }
                onLine?.invoke(line)
            }
        }
        val errReader = Thread {
            process.errorStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                synchronized(err) { err.append(line).append('\n') }
                onLine?.invoke(line)
            }
        }
        outReader.start()
        errReader.start()
        val code = try {
            process.waitFor()
        } catch (e: InterruptedException) {
            process.destroy()
            -2
        }
        outReader.join(5000)
        errReader.join(5000)
        processes.remove(id)
        val wasCancelled = cancelled.remove(id)
        return mapOf(
            "exitCode" to if (wasCancelled) -2 else code,
            "out" to synchronized(out) { out.toString() },
            "err" to synchronized(err) { err.toString() },
        )
    }

    /** Stops a run; true when it was running. */
    fun cancel(id: String): Boolean {
        val process = processes[id] ?: return false
        cancelled.add(id)
        process.destroy()
        Thread {
            try {
                if (!process.waitFor(3, TimeUnit.SECONDS)) process.destroyForcibly()
            } catch (_: InterruptedException) {
            }
        }.start()
        return true
    }
}
