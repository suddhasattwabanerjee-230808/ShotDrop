package com.bittu.shotdrop

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var card: CardChannel? = null
    private var share: ShareChannel? = null
    private var pose: PoseChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        card = CardChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        share = ShareChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        pose = PoseChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (card?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        card?.dispose()
        card = null
        share?.dispose()
        share = null
        pose?.dispose()
        pose = null
        super.onDestroy()
    }
}
