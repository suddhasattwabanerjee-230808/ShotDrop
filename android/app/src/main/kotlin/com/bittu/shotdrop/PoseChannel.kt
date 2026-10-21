package com.bittu.shotdrop

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Finds the person in a photo for the body tools, on the phone, no network:
 * ML Kit pose detection (Slim's body parts, Hip, Legs, and where Stretch's
 * lines go) and selfie segmentation (the outline Slim reshapes).
 */
class PoseChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "shotdrop/pose")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val detector by lazy {
        PoseDetection.getClient(
            PoseDetectorOptions.Builder().setDetectorMode(PoseDetectorOptions.SINGLE_IMAGE_MODE).build(),
        )
    }

    private val segmenter by lazy {
        Segmentation.getClient(
            SelfieSegmenterOptions.Builder().setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE).build(),
        )
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "detect") return result.notImplemented()
        val width = call.argument<Int>("width")!!
        val height = call.argument<Int>("height")!!
        val rgba = call.argument<ByteArray>("rgba")!!
        worker.execute {
            try {
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
                val pose = Tasks.await(detector.process(InputImage.fromBitmap(bitmap, 0)))
                // The outline is a bonus: Slim still works on what's painted without it.
                val mask = try {
                    outline(bitmap, pose)
                } catch (e: Exception) {
                    null
                }
                bitmap.recycle()
                // landmark type -> [x, y, confidence], x and y as 0..1 of the photo
                val points = HashMap<Int, List<Double>>()
                for (lm in pose.allPoseLandmarks) {
                    points[lm.landmarkType] = listOf(
                        lm.position.x / width.toDouble(),
                        lm.position.y / height.toDouble(),
                        lm.inFrameLikelihood.toDouble(),
                    )
                }
                val out = HashMap<String, Any>()
                out["landmarks"] = points
                if (mask != null) {
                    out["mask"] = mask
                    out["maskWidth"] = width
                    out["maskHeight"] = height
                }
                main.post { result.success(out) }
            } catch (e: Exception) {
                main.post { result.error("pose", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    /**
     * The person's outline, one byte per pixel of [bitmap] (255 = person).
     * Only the box around the pose (when there is one) is segmented, so a
     * person standing small in a wide shot still fills the model's view.
     */
    private fun outline(bitmap: Bitmap, pose: Pose): ByteArray {
        val w = bitmap.width
        val h = bitmap.height
        var left = 0
        var top = 0
        var right = w
        var bottom = h
        val seen = pose.allPoseLandmarks.filter { it.inFrameLikelihood > 0.3f }
        if (seen.size >= 6) {
            val xs = seen.map { it.position.x }
            val ys = seen.map { it.position.y }
            val pad = maxOf(xs.max() - xs.min(), ys.max() - ys.min()) * 0.25f
            left = (xs.min() - pad).toInt().coerceIn(0, w - 1)
            right = (xs.max() + pad).toInt().coerceIn(left + 1, w)
            top = (ys.min() - pad).toInt().coerceIn(0, h - 1)
            bottom = (ys.max() + pad).toInt().coerceIn(top + 1, h)
        }
        val cw = right - left
        val ch = bottom - top
        val crop = if (cw == w && ch == h) bitmap else Bitmap.createBitmap(bitmap, left, top, cw, ch)
        val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(crop, 0)))
        if (crop !== bitmap) crop.recycle()
        val mw = mask.width
        val mh = mask.height
        val buffer = mask.buffer
        buffer.rewind()
        val confidence = FloatArray(mw * mh)
        for (i in confidence.indices) confidence[i] = buffer.float
        // The mask is normally the crop's size; scale in case it isn't.
        val out = ByteArray(w * h)
        for (y in 0 until ch) {
            val my = y * mh / ch
            for (x in 0 until cw) {
                val mx = x * mw / cw
                out[(top + y) * w + left + x] = (confidence[my * mw + mx] * 255f).toInt().coerceIn(0, 255).toByte()
            }
        }
        return out
    }
}
