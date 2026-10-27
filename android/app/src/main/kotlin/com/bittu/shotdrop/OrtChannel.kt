package com.bittu.shotdrop

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Runs ONNX models for Remove People (lib/people/): a person finder, a
 * person outliner and LaMa, which paints what's behind them. The models are
 * downloaded once into the app's files (lib/people/model_store.dart), so
 * this only loads a file and runs it: Dart sends the input tensors, gets the
 * output tensors back, and does all the work around them.
 */
class OrtChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "shotdrop/ort")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val env by lazy { OrtEnvironment.getEnvironment() }
    private val sessions = HashMap<String, OrtSession>()

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.execute { closeAll() }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "run" -> {
                val model = call.argument<String>("model")!!
                val inputs = call.argument<List<Map<String, Any?>>>("inputs")!!
                worker.execute {
                    // Throwable: a missing native library is an Error, and Dart must still hear back.
                    try {
                        val out = run(model, inputs)
                        main.post { result.success(out) }
                    } catch (e: Throwable) {
                        main.post { result.error("ort", "${e.javaClass.simpleName}: ${e.message ?: ""}", e.stackTraceToString().take(2000)) }
                    }
                }
            }
            // The models take a few hundred MB loaded; let them go when the job's done.
            "close" -> worker.execute {
                closeAll()
                main.post { result.success(null) }
            }
            else -> result.notImplemented()
        }
    }

    private fun session(path: String): OrtSession = sessions.getOrPut(path) {
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(4)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        env.createSession(path, options)
    }

    private fun closeAll() {
        for (s in sessions.values) runCatching { s.close() }
        sessions.clear()
    }

    /** Each tensor: name, type ("f32" or "u8"), shape, and its bytes (native order). */
    private fun run(model: String, inputs: List<Map<String, Any?>>): List<Map<String, Any?>> {
        val tensors = LinkedHashMap<String, OnnxTensor>()
        try {
            for (input in inputs) {
                val name = input["name"] as String
                val shape = (input["shape"] as List<*>).map { (it as Number).toLong() }.toLongArray()
                val bytes = input["data"] as ByteArray
                val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes)
                buffer.rewind()
                tensors[name] = when (input["type"]) {
                    "f32" -> OnnxTensor.createTensor(env, buffer.asFloatBuffer(), shape)
                    "u8" -> OnnxTensor.createTensor(env, buffer, shape, OnnxJavaType.UINT8)
                    else -> throw IllegalArgumentException("Unknown tensor type ${input["type"]}")
                }
            }
            session(model).run(tensors).use { results ->
                return results.map { (name, value) ->
                    val t = value as OnnxTensor
                    val shape = t.info.shape.toList()
                    when (t.info.type) {
                        OnnxJavaType.FLOAT -> {
                            val floats = t.floatBuffer
                            val out = ByteBuffer.allocate(floats.remaining() * 4).order(ByteOrder.nativeOrder())
                            out.asFloatBuffer().put(floats)
                            mapOf("name" to name, "type" to "f32", "shape" to shape, "data" to out.array())
                        }
                        OnnxJavaType.UINT8 -> {
                            val bytes = t.byteBuffer
                            val out = ByteArray(bytes.remaining())
                            bytes.get(out)
                            mapOf("name" to name, "type" to "u8", "shape" to shape, "data" to out)
                        }
                        else -> throw IllegalStateException("Unexpected output type ${t.info.type}")
                    }
                }
            }
        } finally {
            for (t in tensors.values) t.close()
        }
    }
}
