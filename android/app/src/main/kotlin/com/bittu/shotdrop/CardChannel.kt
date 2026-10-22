package com.bittu.shotdrop

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Reads the camera's SD card (plugged in over OTG) through the Storage Access
 * Framework, and writes the JPEGs Flutter shows and posts. Flutter can't open
 * content:// uris, so every image it displays is a file this side produced.
 */
class CardChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val methods = MethodChannel(messenger, "shotdrop/card")
    private val events = EventChannel(messenger, "shotdrop/card/events")
    private val main = Handler(Looper.getMainLooper())

    // Card reads are slow (USB 2 over OTG), so a few at a time, newest request first: the
    // photos on screen now load before the ones scrolled past. Listing gets its own thread.
    private val io = ThreadPoolExecutor(3, 3, 0L, TimeUnit.MILLISECONDS, object : LinkedBlockingDeque<Runnable>() {
        override fun offer(e: Runnable): Boolean = offerFirst(e)
    })
    private val lister = Executors.newSingleThreadExecutor()

    private var pendingPick: MethodChannel.Result? = null
    private var pendingPhotos: MethodChannel.Result? = null
    private var volumeReceiver: BroadcastReceiver? = null
    private var volumeCallback: Any? = null // StorageManager.StorageVolumeCallback, API 30+
    private val storage by lazy { activity.getSystemService(StorageManager::class.java) }

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
                // Newer phones also report volumes coming and going here, sometimes when the broadcast doesn't.
                if (Build.VERSION.SDK_INT >= 30) {
                    val callback = object : StorageManager.StorageVolumeCallback() {
                        override fun onStateChanged(volume: StorageVolume) {
                            main.post { sink.success(volume.state) }
                        }
                    }
                    storage.registerStorageVolumeCallback(activity.mainExecutor, callback)
                    volumeCallback = callback
                }
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
        if (Build.VERSION.SDK_INT >= 30) {
            (volumeCallback as? StorageManager.StorageVolumeCallback)?.let {
                runCatching { storage.unregisterStorageVolumeCallback(it) }
            }
        }
        volumeCallback = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "phoneAccess" -> result.success(phoneAccess())
            "requestPhoneAccess" -> requestPhoneAccess(result)
            "phoneList" -> background(result, lister) { phoneList() }
            "access" -> background(result, lister) { access(Uri.parse(call.argument<String>("treeUri"))) }
            "findCard" -> background(result, lister) { findCard() }
            "cardVolume" -> background(result, lister) { removableVolume()?.getDescription(activity) }
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
        // With a card plugged in, open the picker right on its DCIM folder: one tap on "Use this folder".
        val volume = removableVolume()
        val intent = (
            if (volume != null && volume.uuid != null) {
                volume.createOpenDocumentTreeIntent().apply {
                    putExtra(
                        DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE, "${volume.uuid}:DCIM"),
                    )
                }
            } else {
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            }
        ).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, PICK_FOLDER)
    }

    /** A plugged-in card (SD reader, USB drive), if any. */
    private fun removableVolume(): StorageVolume? = storage.storageVolumes.firstOrNull {
        it.isRemovable && !it.isPrimary && it.state == Environment.MEDIA_MOUNTED
    }

    /**
     * A folder picked before (its permission is kept) that can be read now,
     * because its card is plugged in: so each card only has to be picked
     * once, ever. Folders on cards, and DCIM folders, come first.
     */
    private fun findCard(): String? {
        val trees = activity.contentResolver.persistedUriPermissions
            .filter { it.isReadPermission }
            .mapNotNull { p -> runCatching { p.uri to DocumentsContract.getTreeDocumentId(p.uri) }.getOrNull() }
            .sortedBy { (_, id) -> (if (id.startsWith("primary:")) 2 else 0) + (if (id.contains("DCIM", true)) 0 else 1) }
        return trees.firstOrNull { (uri, _) -> access(uri) == "ok" }?.first?.toString()
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

    // --- The phone's own gallery ------------------------------------------------

    /** "all", "partial" (Android 14+: only photos the user picked), or "none". */
    private fun phoneAccess(): String {
        fun has(p: String) = activity.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 33 && has(Manifest.permission.READ_MEDIA_IMAGES) -> "all"
            Build.VERSION.SDK_INT < 33 && has(Manifest.permission.READ_EXTERNAL_STORAGE) -> "all"
            Build.VERSION.SDK_INT >= 34 && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
            else -> "none"
        }
    }

    private val photoPermission
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE

    /** Asks for the photos; answers like [phoneAccess], or "blocked" once Android won't ask again. */
    private fun requestPhoneAccess(result: MethodChannel.Result) {
        pendingPhotos?.success(phoneAccess())
        pendingPhotos = result
        val asking = if (Build.VERSION.SDK_INT >= 34) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        } else {
            arrayOf(photoPermission)
        }
        activity.requestPermissions(asking, PHOTOS_REQUEST)
    }

    /** From MainActivity: the answer to [requestPhoneAccess]. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PHOTOS_REQUEST) return false
        val access = phoneAccess()
        val blocked = access == "none" && !activity.shouldShowRequestPermissionRationale(photoPermission)
        pendingPhotos?.success(if (blocked) "blocked" else access)
        pendingPhotos = null
        return true
    }

    /** Every photo in the phone's gallery, newest first (not ShotDrop's own copies). */
    private fun phoneList(): List<Map<String, Any?>> {
        val base = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            base,
            arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_MODIFIED,
            ),
            "(${MediaStore.Images.Media.RELATIVE_PATH} IS NULL OR ${MediaStore.Images.Media.RELATIVE_PATH} NOT LIKE ?)",
            arrayOf("${Environment.DIRECTORY_PICTURES}/ShotDrop/%"),
            "${MediaStore.Images.Media.DATE_TAKEN} DESC, ${MediaStore.Images.Media.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val taken = c.getLong(3).takeIf { it > 0 } ?: (c.getLong(4) * 1000)
                out.add(
                    mapOf(
                        "uri" to ContentUris.withAppendedId(base, id).toString(),
                        "docId" to "phone:$id",
                        "name" to (c.getString(1) ?: "IMG_$id.jpg"),
                        "size" to c.getLong(2),
                        "modified" to taken,
                    ),
                )
            }
        }
        return out
    }

    // --- Images ---------------------------------------------------------------

    private fun thumbnail(uri: Uri, key: String, maxEdge: Int, fast: Boolean): String? {
        val dir = File(activity.cacheDir, "thumbs").apply { mkdirs() }
        val file = File(dir, sha1("$key|$maxEdge|$fast") + ".jpg")
        if (file.exists() && file.length() > 0) {
            file.setLastModified(System.currentTimeMillis()) // used: the storage tidy-up keeps it longer
            return file.absolutePath
        }
        // Phone photos: Android keeps thumbnails of its own (upright, any format). Card JPEGs
        // carry previews: a ~640 px one after the photo (MPF, Nikon and others), a tiny one in EXIF.
        val bitmap = when {
            uri.authority == MediaStore.AUTHORITY && (fast || maxEdge <= 512) ->
                runCatching { activity.contentResolver.loadThumbnail(uri, android.util.Size(maxEdge, maxEdge), null) }.getOrNull()
                    ?: decodeUpright(uri, maxEdge)
            fast -> decodeMpfPreview(uri, maxOf(maxEdge, 640), 0) ?: decodeExifThumbnail(uri)
            else -> decodeMpfPreview(uri, maxEdge, maxEdge) ?: decodeUpright(uri, maxEdge)
        } ?: return null
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

    /**
     * The preview a camera stores after the photo itself in an MPF block (Nikon's is
     * 640 px), decoded at most [maxEdge] and turned upright; null if there's none at
     * least [minEdge] px. Only the file's header and the preview are read, a few
     * dozen KB instead of the whole 10 MB photo, so a card gallery fills in fast.
     */
    private fun decodeMpfPreview(uri: Uri, maxEdge: Int, minEdge: Int): Bitmap? = runCatching {
        activity.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            val fd = pfd.fileDescriptor
            fun read(at: Long, n: Int): ByteArray? {
                if (n <= 0) return null
                val buf = ByteArray(n)
                var got = 0
                while (got < n) {
                    val r = Os.pread(fd, buf, got, n - got, at + got)
                    if (r <= 0) return null
                    got += r
                }
                return buf
            }
            val (at, size) = findMpfPreview(::read) ?: return@use null
            val bytes = read(at, size) ?: return@use null
            if (bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return@use null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (maxOf(bounds.outWidth, bounds.outHeight) < maxOf(minEdge, 1)) return@use null
            val options = BitmapFactory.Options().apply { inSampleSize = sampleFor(bounds, maxEdge) }
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return@use null
            // The preview is stored sideways like the photo; the photo's EXIF says which way is up.
            val orientation = ExifInterface(fd).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            upright(decoded, orientation, minOf(1f, maxEdge.toFloat() / maxOf(decoded.width, decoded.height)))
        }
    }.getOrNull()

    /** The whole photo, decoded at roughly [maxEdge] and turned upright. The file is read once. */
    private fun decodeUpright(uri: Uri, maxEdge: Int): Bitmap? {
        val bytes = activity.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            // A NEF without a JPEG twin: fall back to the preview inside it.
            return decodeExifThumbnail(uri)
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleFor(bounds, maxEdge) }
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val orientation = runCatching {
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val scale = minOf(1f, maxEdge.toFloat() / maxOf(decoded.width, decoded.height))
        return upright(decoded, orientation, scale)
    }

    /** The largest power-of-two shrink that still leaves at least [maxEdge] px. */
    private fun sampleFor(bounds: BitmapFactory.Options, maxEdge: Int): Int {
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdge) sample *= 2
        return sample
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

    // --- MPF (CIPA DC-007): the JPEG segment listing the extra images after the photo ---

    /** Where in the file the largest extra image starts, and its size; null if the JPEG has no MPF. */
    private fun findMpfPreview(read: (Long, Int) -> ByteArray?): Pair<Long, Int>? {
        val soi = read(0, 2) ?: return null
        if (soi[0] != 0xFF.toByte() || soi[1] != 0xD8.toByte()) return null
        var at = 2L
        repeat(40) {
            val head = read(at, 4) ?: return null
            if (head[0] != 0xFF.toByte()) return null
            val marker = head[1].toInt() and 0xFF
            if (marker == 0xDA || marker == 0xD9) return null // the pixels start: no MPF before them
            val length = ((head[2].toInt() and 0xFF) shl 8) or (head[3].toInt() and 0xFF)
            if (marker == 0xE2 && length > 16) {
                val seg = read(at + 4, length - 2) ?: return null
                if (seg[0] == 'M'.code.toByte() && seg[1] == 'P'.code.toByte() && seg[2] == 'F'.code.toByte() && seg[3] == 0.toByte()) {
                    return runCatching { parseMpf(seg, at + 8) }.getOrNull()
                }
            }
            at += 2 + length
        }
        return null
    }

    /** [seg] is the APP2 segment's data: "MPF\0", then a TIFF block (at [tiffAt] in the file) that offsets count from. */
    private fun parseMpf(seg: ByteArray, tiffAt: Long): Pair<Long, Int>? {
        val base = 4
        val little = seg[base] == 'I'.code.toByte()
        fun u8(i: Int) = seg[i].toInt() and 0xFF
        fun u16(i: Int) = if (little) u8(i) or (u8(i + 1) shl 8) else (u8(i) shl 8) or u8(i + 1)
        fun u32(i: Int): Long = if (little) {
            u16(i).toLong() or (u16(i + 2).toLong() shl 16)
        } else {
            (u16(i).toLong() shl 16) or u16(i + 2).toLong()
        }
        val ifd = base + u32(base + 4).toInt()
        for (k in 0 until u16(ifd)) {
            val e = ifd + 2 + k * 12
            if (u16(e) != 0xB002) continue // MP Entry: 16 bytes per image, the photo itself first
            val images = (u32(e + 4) / 16).toInt()
            val list = base + u32(e + 8).toInt()
            var best: Pair<Long, Int>? = null
            for (j in 1 until images) {
                // Only the "large thumbnail" kinds (0x01000x): an Ultra HDR photo's gain map is an MPF image too.
                if ((u32(list + j * 16) and 0xFF0000L) != 0x010000L) continue
                val size = u32(list + j * 16 + 4)
                val offset = u32(list + j * 16 + 8)
                if (offset > 0 && size in 1L..8_000_000L && size > (best?.second ?: 0)) best = (tiffAt + offset) to size.toInt()
            }
            return best
        }
        return null
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        private const val PICK_FOLDER = 4201
        private const val PHOTOS_REQUEST = 4202
        private const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
        private val PHOTO_EXTENSIONS = setOf("JPG", "JPEG", "NEF", "NRW")
    }
}
