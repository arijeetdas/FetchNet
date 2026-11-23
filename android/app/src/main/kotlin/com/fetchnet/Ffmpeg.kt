package com.fetchnet

import android.content.Context
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Runs the FFmpeg (or ffprobe) that ships with youtubedl-android, for the
 * work yt-dlp doesn't do itself: Shorts/Reels conversion and snapshots.
 * Its libraries live in the unpacked "ffmpeg" package, and the C++ runtime
 * it needs in the "python" one (see [GalleryDl]).
 */
class Ffmpeg(private val context: Context) {

    private val processes = ConcurrentHashMap<String, Process>()
    private val cancelled: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private val packages get() = File(File(context.noBackupFilesDir, "youtubedl-android"), "packages")

    /** `true` when [id] was an FFmpeg run (now stopped). */
    fun cancel(id: String): Boolean {
        val process = processes[id] ?: return false
        cancelled += id
        process.destroy()
        return true
    }

    fun run(id: String, args: List<String>, probe: Boolean, onLine: (String) -> Unit): Map<String, Any?> {
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val exe = File(nativeDir, if (probe) "libffprobe.so" else "libffmpeg.so")
        // FFmpeg's own libraries, and Python's: libc++_shared.so ships only
        // in the Python package (youtubedl-android puts both on the path for
        // yt-dlp the same way).
        val libs = listOf(File(packages, "ffmpeg/usr/lib"), File(packages, "python/usr/lib"))
        if (!exe.exists() || libs.any { !it.exists() }) {
            return mapOf("exitCode" to -1, "out" to "", "err" to "FFmpeg isn't ready yet. Wait for yt-dlp to finish starting.")
        }
        val builder = ProcessBuilder(listOf(exe.absolutePath) + args).directory(context.cacheDir)
        val env = builder.environment()
        env["LD_LIBRARY_PATH"] = libs.joinToString(":") { it.absolutePath }
        env["TMPDIR"] = context.cacheDir.absolutePath
        env["HOME"] = context.cacheDir.absolutePath
        val process = try {
            builder.start()
        } catch (e: Exception) {
            return mapOf("exitCode" to -1, "out" to "", "err" to "Couldn't start FFmpeg: ${e.message}")
        }
        processes[id] = process
        val out = StringBuilder()
        val err = StringBuilder()
        val outReader = Thread {
            process.inputStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                synchronized(out) { out.append(line).append('\n') }
                onLine(line)
            }
        }
        val errReader = Thread {
            process.errorStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                synchronized(err) {
                    // Only the end matters for errors; FFmpeg can be chatty.
                    if (err.length > 64_000) err.delete(0, err.length - 32_000)
                    err.append(line).append('\n')
                }
                onLine(line)
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
        outReader.join(2000)
        errReader.join(2000)
        processes.remove(id)
        val wasCancelled = cancelled.remove(id)
        return mapOf(
            "exitCode" to if (wasCancelled) -2 else code,
            "out" to synchronized(out) { out.toString() },
            "err" to synchronized(err) { err.toString() },
        )
    }
}
