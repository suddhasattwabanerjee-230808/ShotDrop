package com.bittu.shotdrop

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.Rect
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.atan2
import kotlin.math.max

/**
 * The People filter and the auto-turn, on the phone, no network. For each
 * photo: ML Kit finds the faces (and, in a landscape photo with no upright
 * face, whether a person is lying sideways: a face found once the photo is
 * turned), then MobileFaceNet (assets/MobileFaceNet.tflite, MIT) turns each
 * face into 192 numbers that are close for the same person. Dart groups them.
 */
class FaceChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val preview: (Uri, Int) -> Bitmap?,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "shotdrop/faces")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    private val detector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setMinFaceSize(0.06f)
                .build(),
        )
    }

    // Null if the model won't load: faces are still found (and photos turned), just not grouped.
    private val embedder: Interpreter? by lazy {
        runCatching {
            val bytes = activity.assets.open(MODEL).use { it.readBytes() }
            val model = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes)
            model.rewind()
            Interpreter(model, Interpreter.Options().setNumThreads(2))
        }.getOrNull()
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "scan") return result.notImplemented()
        val uri = Uri.parse(call.argument<String>("uri")!!)
        val key = call.argument<String>("key")!!
        worker.execute {
            try {
                val out = scan(uri, key)
                main.post { result.success(out) }
            } catch (e: Exception) {
                main.post { result.error("faces", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun scan(uri: Uri, key: String): Map<String, Any> {
        var photo = preview(uri, EDGE) ?: throw IllegalStateException("Couldn't read this photo")
        try {
            var turn = 0
            var faces = detect(photo)
            // Landscape and nobody upright: is someone lying sideways? Left 90° first, the usual way.
            if (photo.width > photo.height && faces.isEmpty()) {
                val base = photo
                for (q in intArrayOf(3, 1)) {
                    val turned = rotate(base, q)
                    val found = detect(turned)
                    if (score(found) > score(faces)) {
                        if (photo !== base) photo.recycle()
                        photo = turned
                        faces = found
                        turn = q
                    } else {
                        turned.recycle()
                    }
                }
                if (photo !== base) base.recycle()
            }
            return mapOf("turn" to turn, "faces" to describe(photo, faces.take(MAX_FACES), key))
        } finally {
            photo.recycle()
        }
    }

    /** Faces with both eyes showing, biggest first. */
    private fun detect(bitmap: Bitmap): List<Face> {
        val found = Tasks.await(detector.process(InputImage.fromBitmap(bitmap, 0)))
        return found
            .filter { it.getLandmark(FaceLandmark.LEFT_EYE) != null && it.getLandmark(FaceLandmark.RIGHT_EYE) != null }
            .sortedByDescending { it.boundingBox.width() * it.boundingBox.height() }
    }

    private fun score(faces: List<Face>): Int = faces.sumOf { it.boundingBox.width() * it.boundingBox.height() }

    private fun rotate(bitmap: Bitmap, q: Int): Bitmap =
        Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(90f * q) }, true)

    private fun describe(photo: Bitmap, faces: List<Face>, key: String): List<Map<String, Any>> {
        if (faces.isEmpty()) return emptyList()
        val dir = File(activity.filesDir, "faces").apply { mkdirs() }
        val stem = sha1(key)
        val big = faces.filter { minOf(it.boundingBox.width(), it.boundingBox.height()) >= MIN_EMBED_PX }
        val embeddings = embed(photo, big)
        return faces.mapIndexed { i, face ->
            val box = face.boundingBox
            val crop = File(dir, "$stem-$i.jpg")
            FileOutputStream(crop).use { aligned(photo, face, AVATAR, 1.7f).run { compress(Bitmap.CompressFormat.JPEG, 85, it); recycle() } }
            val m = HashMap<String, Any>()
            m["box"] = listOf(
                box.left / photo.width.toDouble(),
                box.top / photo.height.toDouble(),
                box.right / photo.width.toDouble(),
                box.bottom / photo.height.toDouble(),
            )
            m["crop"] = crop.absolutePath
            embeddings[face]?.let { m["embedding"] = it }
            m
        }
    }

    /** Each face's 192 numbers, unit length, as little-endian float32 bytes. */
    private fun embed(photo: Bitmap, faces: List<Face>): Map<Face, ByteArray> {
        val net = embedder ?: return emptyMap()
        val input = net.getInputTensor(0).shape() // [batch, size, size, 3]
        val batch = input[0]
        val size = input[1]
        val dim = net.getOutputTensor(0).shape()[1]
        val out = HashMap<Face, ByteArray>()
        for (group in faces.chunked(batch)) {
            val buffer = ByteBuffer.allocateDirect(batch * size * size * 3 * 4).order(ByteOrder.nativeOrder())
            val pixels = IntArray(size * size)
            for (slot in 0 until batch) {
                // The model takes a fixed batch: pad with the last face.
                val crop = aligned(photo, group[minOf(slot, group.size - 1)], size, 1.0f)
                crop.getPixels(pixels, 0, size, 0, 0, size, size)
                crop.recycle()
                for (p in pixels) {
                    buffer.putFloat(((p shr 16 and 0xFF) - 127.5f) / 128f)
                    buffer.putFloat(((p shr 8 and 0xFF) - 127.5f) / 128f)
                    buffer.putFloat(((p and 0xFF) - 127.5f) / 128f)
                }
            }
            buffer.rewind()
            val result = Array(batch) { FloatArray(dim) }
            net.run(buffer, result)
            group.forEachIndexed { i, face ->
                val v = result[i]
                var norm = 0.0
                for (x in v) norm += x * x
                val scale = (1.0 / max(Math.sqrt(norm), 1e-10)).toFloat()
                val bytes = ByteBuffer.allocate(dim * 4).order(ByteOrder.LITTLE_ENDIAN)
                for (x in v) bytes.putFloat(x * scale)
                out[face] = bytes.array()
            }
        }
        return out
    }

    /** The face, eyes level, as a [size] px square [zoom] times its box. */
    private fun aligned(photo: Bitmap, face: Face, size: Int, zoom: Float): Bitmap {
        val box: Rect = face.boundingBox
        val a: PointF = face.getLandmark(FaceLandmark.LEFT_EYE)!!.position
        val b: PointF = face.getLandmark(FaceLandmark.RIGHT_EYE)!!.position
        val (l, r) = if (a.x <= b.x) a to b else b to a
        val roll = Math.toDegrees(atan2((r.y - l.y).toDouble(), (r.x - l.x).toDouble())).toFloat()
        val side = max(box.width(), box.height()) * zoom
        val m = Matrix().apply {
            postTranslate(-box.exactCenterX(), -box.exactCenterY())
            postRotate(-roll)
            postScale(size / side, size / side)
            postTranslate(size / 2f, size / 2f)
        }
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(photo, m, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return out
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        const val MODEL = "MobileFaceNet.tflite"
        const val EDGE = 640 // Nikon's MPF preview size: no full-photo read off the card
        const val MAX_FACES = 8
        const val MIN_EMBED_PX = 28 // smaller faces are too blurry to tell people apart
        const val AVATAR = 160
    }
}
