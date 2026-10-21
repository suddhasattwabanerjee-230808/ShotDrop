package com.bittu.shotdrop

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Reads the camera's SD card (plugged in over OTG) through the Storage Access
 * Framework, and writes the JPEGs Flutter shows and posts. Flutter can't open
 * content:// uris, so every image it displays is a file this side produced.
 */
class CardChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val methods = MethodChannel(messenger, "shotdrop/card")
    private val events = EventChannel(messenger, "shotdrop/card/events")
    private val main = Handler(Looper.getMainLooper())

    // Card reads are slow (USB 2 over OTG), so a few at a time; listing gets its own thread.
    private val io = Executors.newFixedThreadPool(3)
    private val lister = Executors.newSingleThreadExecutor()

    private var pendingPick: MethodChannel.Result? = null
    private var volumeReceiver: BroadcastReceiver? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        sink.success(intent.action)
                    }
                }
                val filter = IntentFilter().apply {
                    addAction(Intent.ACTION_MEDIA_MOUNTED)
                    addAction(Intent.ACTION_MEDIA_UNMOUNTED)
                    addAction(Intent.ACTION_MEDIA_REMOVED)
                    addAction(Intent.ACTION_MEDIA_EJECT)
                    addDataScheme("file")
                }
                if (Build.VERSION.SDK_INT >= 33) {
                    activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
                } else {
                    activity.registerReceiver(receiver, filter)
                }
                volumeReceiver = receiver
            }

            override fun onCancel(arguments: Any?) = unregisterVolumes()
        })
    }

    fun dispose() {
        unregisterVolumes()
        methods.setMethodCallHandler(null)
        io.shutdown()
        lister.shutdown()
    }

    private fun unregisterVolumes() {
        volumeReceiver?.let { runCatching { activity.unregisterReceiver(it) } }
        volumeReceiver = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "access" -> background(result, lister) { access(Uri.parse(call.argument<String>("treeUri"))) }
            "list" -> background(result, lister) { list(Uri.parse(call.argument<String>("treeUri"))) }
            "thumbnail" -> background(result) {
                thumbnail(
                    Uri.parse(call.argument<String>("uri")),
                    call.argument<String>("key")!!,
                    call.argument<Int>("maxEdge")!!,
                    call.argument<Boolean>("fast") ?: false,
                )
            }
            "importSource" -> background(result) {
                val bitmap = decodeUpright(Uri.parse(call.argument<String>("uri")), call.argument<Int>("maxEdge")!!)
                    ?: throw IllegalStateException("Couldn't read this photo from the card")
                writeJpeg(bitmap, File(call.argument<String>("dest")!!), 95)
                bitmap.recycle()
                null
            }
            "encodeJpeg" -> background(result) {
                val width = call.argument<Int>("width")!!
                val height = call.argument<Int>("height")!!
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(call.argument<ByteArray>("rgba")!!))
                writeJpeg(bitmap, File(call.argument<String>("dest")!!), call.argument<Int>("quality") ?: 92)
                bitmap.recycle()
                null
            }
            "saveToGallery" -> background(result) {
                saveToGallery(
                    File(call.argument<String>("path")!!),
                    call.argument<String>("name")!!,
                    call.argument<String>("album")!!,
                )
            }
            "deleteFromGallery" -> background(result) {
                runCatching { activity.contentResolver.delete(Uri.parse(call.argument<String>("uri")), null, null) }
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, pool: java.util.concurrent.ExecutorService = io, work: () -> Any?) {
        pool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("card", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    // --- Folder access --------------------------------------------------------

    private fun pickFolder(result: MethodChannel.Result) {
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, PICK_FOLDER)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FOLDER) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        runCatching {
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        result.success(uri.toString())
        return true
    }

    /** "ok", "noPermission" (folder forgotten) or "missing" (card not plugged in). */
    private fun access(tree: Uri): String {
        val granted = activity.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
        if (!granted) return "noPermission"
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return try {
            activity.contentResolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)
                ?.use { if (it.moveToFirst()) "ok" else "missing" } ?: "missing"
        } catch (e: Exception) {
            "missing"
        }
    }

    // --- Listing --------------------------------------------------------------

    private fun list(tree: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        walk(tree, DocumentsContract.getTreeDocumentId(tree), 0, out)
        return out
    }

    private fun walk(tree: Uri, parentId: String, depth: Int, out: MutableList<Map<String, Any?>>) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        activity.contentResolver.query(children, columns, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                if (name.startsWith(".")) continue
                if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    // DCIM/100D5600/... is two levels down from the card root.
                    if (depth < 4) walk(tree, id, depth + 1, out)
                    continue
                }
                val ext = name.substringAfterLast('.', "").uppercase()
                if (ext !in PHOTO_EXTENSIONS) continue
                out.add(
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                        "docId" to id,
                        "name" to name,
                        "size" to c.getLong(3),
                        "modified" to c.getLong(4),
                    ),
                )
            }
        }
    }

    // --- Images ---------------------------------------------------------------

    private fun thumbnail(uri: Uri, key: String, maxEdge: Int, fast: Boolean): String? {
        val dir = File(activity.cacheDir, "thumbs").apply { mkdirs() }
        val file = File(dir, sha1("$key|$maxEdge|$fast") + ".jpg")
        if (file.exists() && file.length() > 0) return file.absolutePath
        val bitmap = (if (fast) decodeExifThumbnail(uri) else decodeUpright(uri, maxEdge)) ?: return null
        writeJpeg(bitmap, file, if (fast) 80 else 88)
        bitmap.recycle()
        return file.absolutePath
    }

    /** The small preview the camera embeds in the file's EXIF data: read without touching the pixels. */
    private fun decodeExifThumbnail(uri: Uri): Bitmap? {
        val (orientation, bitmap) = activity.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            val exif = ExifInterface(pfd.fileDescriptor)
            exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) to exif.thumbnailBitmap
        } ?: return null
        return bitmap?.let { upright(it, orientation) }
    }

    /** The whole photo, decoded at roughly [maxEdge] and turned upright. */
    private fun decodeUpright(uri: Uri, maxEdge: Int): Bitmap? {
        val resolver = activity.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            // A NEF without a JPEG twin: fall back to the preview inside it.
            return decodeExifThumbnail(uri)
        }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdge) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        val orientation = resolver.openFileDescriptor(uri, "r")?.use {
            ExifInterface(it.fileDescriptor).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } ?: ExifInterface.ORIENTATION_NORMAL
        val scale = minOf(1f, maxEdge.toFloat() / maxOf(decoded.width, decoded.height))
        return upright(decoded, orientation, scale)
    }

    private fun upright(bitmap: Bitmap, orientation: Int, scale: Float = 1f): Bitmap {
        val m = Matrix()
        if (scale < 1f) m.postScale(scale, scale)
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
        }
        if (m.isIdentity) return bitmap
        val out = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        if (out !== bitmap) bitmap.recycle()
        return out
    }

    private fun writeJpeg(bitmap: Bitmap, file: File, quality: Int) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".part")
        FileOutputStream(tmp).use { bitmap.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        if (!tmp.renameTo(file)) {
            tmp.copyTo(file, overwrite = true)
            tmp.delete()
        }
    }

    // --- Gallery --------------------------------------------------------------

    private fun saveToGallery(file: File, name: String, album: String): String {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$album")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: throw IllegalStateException("Couldn't add the photo to the gallery")
        resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        return uri.toString()
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        private const val PICK_FOLDER = 4201
        private val PHOTO_EXTENSIONS = setOf("JPG", "JPEG", "NEF", "NRW")
    }
}
