package com.bittu.shotdrop

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var card: CardChannel? = null
    private var share: ShareChannel? = null
    private var pose: PoseChannel? = null
    private var faces: FaceChannel? = null
    private var app: AppChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val cards = CardChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        card = cards
        faces = FaceChannel(this, flutterEngine.dartExecutor.binaryMessenger, cards::preview)
        share = ShareChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        pose = PoseChannel(flutterEngine.dartExecutor.binaryMessenger)
        app = AppChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        CaptionService.stopWatching()
    }

    // Already open, and a card was plugged in: show the Gallery.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (CardPlugReceiver.isCard(intent)) app?.cardPlugged()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        card?.onPermissionResult(requestCode)
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
        faces?.dispose()
        faces = null
        app?.dispose()
        app = null
        super.onDestroy()
    }
}
