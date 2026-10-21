package com.bittu.shotdrop

import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Leaves a note in Download when ShotDrop crashes, so a crash on the phone
 * can be read without a computer: Java crashes as they happen, and (Android
 * 11+) the reason the previous run ended, which covers native crashes too.
 * Installed in attachBaseContext, before anything else in the app runs.
 */
class ShotDropApplication : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            runCatching {
                val trace = StringWriter().also { e.printStackTrace(PrintWriter(it)) }.toString()
                CrashLog.write(this, "Crashed in thread \"${thread.name}\"\n\n$trace")
            }
            previous?.uncaughtException(thread, e)
        }
        runCatching { CrashLog.reportLastExit(this) }
    }
}

object CrashLog {
    /** Writes [text] to Download/ShotDrop-crash-<time>[suffix], with the app and phone versions on top. */
    fun write(context: Context, text: String, suffix: String = ".txt", raw: ByteArray? = null) {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val header = "ShotDrop ${info.versionName} (${info.longVersionCode}) · Android ${Build.VERSION.RELEASE} " +
            "(SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}\n\n"
        val name = "ShotDrop-crash-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + suffix
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, if (raw != null) "application/octet-stream" else "text/plain")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return
        context.contentResolver.openOutputStream(uri)?.use { it.write(raw ?: (header + text).toByteArray()) }
    }

    /** If the previous run crashed (or froze), says why, once. */
    fun reportLastExit(context: Context) {
        if (Build.VERSION.SDK_INT < 30) return
        val am = context.getSystemService(ActivityManager::class.java)
        val last = am.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull() ?: return
        val kind = when (last.reason) {
            ApplicationExitInfo.REASON_CRASH -> "Java crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
            ApplicationExitInfo.REASON_ANR -> "froze (ANR)"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
            else -> return
        }
        val prefs = context.getSharedPreferences("shotdrop.crashlog", Context.MODE_PRIVATE)
        if (prefs.getLong("reported", 0L) == last.timestamp) return
        prefs.edit().putLong("reported", last.timestamp).commit()
        val trace = runCatching { last.traceInputStream?.use { it.readBytes() } }.getOrNull()
        write(
            context,
            "The last run ended: $kind\nWhen: ${Date(last.timestamp)}\nStatus: ${last.status}\n" +
                "Description: ${last.description}\nProcess: ${last.processName}\n" +
                (if (trace != null) "A trace was saved next to this file (.trace).\n" else ""),
        )
        if (trace != null) write(context, "", ".trace", trace)
    }
}
