package com.bittu.shotdrop

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The app itself: its version and installing an update (the APK is
 * downloaded on the Flutter side), the caption helper's switch in
 * Accessibility settings, the saved settings, and noting Dart errors.
 */
class AppChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "shotdrop/app")

    // Settings live in Android's own SharedPreferences, read and written here.
    // (The shared_preferences plugin didn't work in release builds: nothing
    // was saved, and 0.5.2 waited on it forever at a black screen.)
    private val prefs by lazy { activity.getSharedPreferences("shotdrop.settings", Context.MODE_PRIVATE) }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "prefs" -> result.success(HashMap<String, Any?>(prefs.all))
                "setPref" -> {
                    val key = call.argument<String>("key")!!
                    val edit = prefs.edit()
                    when (val v = call.argument<Any?>("value")) {
                        null -> edit.remove(key)
                        is Boolean -> edit.putBoolean(key, v)
                        is Int -> edit.putInt(key, v)
                        is Long -> edit.putInt(key, v.toInt())
                        else -> edit.putString(key, v.toString())
                    }
                    edit.apply()
                    result.success(null)
                }
                // A Dart error (the app keeps going): noted in Download like a crash.
                "logError" -> {
                    CrashLog.write(activity, call.argument<String>("text") ?: "", suffix = "-dart.txt")
                    result.success(null)
                }
                "version" -> {
                    val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                    result.success(mapOf("name" to info.versionName, "code" to info.longVersionCode))
                }
                "install" -> result.success(install(File(call.argument<String>("path")!!)))
                "captionHelperOn" -> result.success(CaptionService.isOn(activity))
                "openAccessibility" -> {
                    activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                "openAppInfo" -> {
                    activity.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("app", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * Hands [apk] to Android's installer: "started", or "needsPermission"
     * (Settings is opened on "Install unknown apps" for ShotDrop; try again after).
     */
    private fun install(apk: File): String {
        if (!activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
            )
            return "needsPermission"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", apk)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }
}
