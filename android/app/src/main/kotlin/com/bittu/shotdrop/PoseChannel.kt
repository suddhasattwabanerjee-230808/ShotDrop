package com.bittu.shotdrop

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Finds the person in a photo for the body tools (Slim, Hip, Legs, and where
 * Stretch's lines go): ML Kit pose detection, on the phone, no network.
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
                main.post { result.success(points) }
            } catch (e: Exception) {
                main.post { result.error("pose", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }
}
