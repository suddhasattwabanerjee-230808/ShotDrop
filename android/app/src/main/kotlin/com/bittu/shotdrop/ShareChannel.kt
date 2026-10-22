package com.bittu.shotdrop

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands edited photos to the Instagram / Facebook apps. A personal Instagram
 * account can't be posted to by any other app, so ShotDrop opens Instagram's
 * own composer (feed or story) with the photos loaded and the user taps Share.
 */
class ShareChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "shotdrop/share")

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "apps" -> result.success(mapOf("instagram" to installed(INSTAGRAM), "facebook" to installed(FACEBOOK)))
                "share" -> {
                    val app = call.argument<String>("app")!!
                    val kind = call.argument<String>("kind")!!
                    // Instagram drops captions sent with a share; CaptionService types it in instead.
                    val caption = call.argument<String>("caption")
                    if (app == "instagram" && kind == "feed" && !caption.isNullOrBlank()) {
                        CaptionService.setPending(activity, caption)
                    }
                    result.success(share(app, kind, call.argument<List<String>>("paths")!!))
                }
                "openUrl" -> result.success(openUrl(call.argument<String>("url")!!, call.argument<String>("app")))
                "moveInGallery" -> {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/${call.argument<String>("album")}")
                    }
                    activity.contentResolver.update(Uri.parse(call.argument<String>("uri")), values, null, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("share", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun installed(pkg: String): Boolean = try {
        @Suppress("DEPRECATION")
        activity.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    /**
     * Opens [app]'s composer of [kind] ("feed" or "story") with [paths].
     * Returns "launched", "chooser" (couldn't tell its feed and story screens
     * apart, so the app's own options were shown), "noMultiple" (it won't take
     * several photos at once) or "notInstalled".
     */
    private fun share(app: String, kind: String, paths: List<String>): String {
        val pkg = if (app == "facebook") FACEBOOK else INSTAGRAM
        if (!installed(pkg)) return "notInstalled"
        val authority = "${activity.packageName}.files"
        val uris = ArrayList(paths.map { FileProvider.getUriForFile(activity, authority, File(it)) })
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        intent.type = "image/jpeg"
        intent.setPackage(pkg)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }

        @Suppress("DEPRECATION")
        val targets = activity.packageManager.queryIntentActivities(intent, 0).map { it.activityInfo }
        if (targets.isEmpty()) return if (uris.size > 1) "noMultiple" else "notInstalled"

        // Instagram registers one share screen per destination (feed, story,
        // chats, reels); pick by the screen's class name.
        val pick = targets.firstOrNull { destination(it) == kind }
        return try {
            if (pick != null) {
                intent.setClassName(pick.packageName, pick.name)
                activity.startActivity(intent)
                if (pkg == INSTAGRAM && CaptionService.isOn(activity)) CaptionService.watchShare(intent)
                "launched"
            } else {
                activity.startActivity(Intent.createChooser(intent, null))
                "chooser"
            }
        } catch (e: ActivityNotFoundException) {
            "notInstalled"
        }
    }

    private fun destination(info: ActivityInfo): String {
        val name = info.name.lowercase()
        return when {
            "story" in name || "stories" in name -> "story"
            "direct" in name || "chat" in name || "message" in name -> "direct"
            "clips" in name || "reel" in name -> "reel"
            else -> "feed"
        }
    }

    private fun openUrl(url: String, app: String?): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        if (app != null) {
            try {
                activity.startActivity(Intent(intent).setPackage(if (app == "facebook") FACEBOOK else INSTAGRAM))
                return true
            } catch (_: ActivityNotFoundException) {
                // Not installed or doesn't open links: fall back to the browser.
            }
        }
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    companion object {
        const val INSTAGRAM = "com.instagram.android"
        const val FACEBOOK = "com.facebook.katana"
    }
}
