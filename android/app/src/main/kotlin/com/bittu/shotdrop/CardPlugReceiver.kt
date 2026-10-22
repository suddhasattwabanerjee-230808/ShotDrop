package com.bittu.shotdrop

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.storage.StorageManager
import java.io.File

/**
 * Opens ShotDrop when a card is plugged in (Settings > Open When A Card Is
 * Plugged In). Two ways in, since phones differ: Android announces the card
 * once it's mounted (this receiver; Android lets it open the app because the
 * caption helper is an accessibility service), and the reader showing up on
 * USB can open ShotDrop directly (the OpenOnCard alias in the manifest;
 * Android asks once whether ShotDrop should always open for it).
 */
class CardPlugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MEDIA_MOUNTED || !enabled(context)) return
        // Only a removable card or reader, not the phone's own storage.
        val path = intent.data?.path ?: return
        val volume = runCatching { context.getSystemService(StorageManager::class.java).getStorageVolume(File(path)) }.getOrNull()
        if (volume?.isPrimary == true || volume?.isRemovable == false) return
        runCatching { context.startActivity(openIntent(context)) }
    }

    companion object {
        /** The setting, as AppSettings saves it. */
        const val SETTING = "shotdrop.settings.openOnCard"
        const val EXTRA_CARD = "shotdrop.card"
        private const val ALIAS = "com.bittu.shotdrop.OpenOnCard"

        private fun enabled(context: Context) =
            context.getSharedPreferences("shotdrop.settings", Context.MODE_PRIVATE).getBoolean(SETTING, true)

        fun openIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_CARD, true)

        /** Switches the USB way in on or off with the setting (the receiver checks the setting itself). */
        fun setEnabled(context: Context, on: Boolean) {
            context.packageManager.setComponentEnabledSetting(
                ComponentName(context.packageName, ALIAS),
                if (on) PackageManager.COMPONENT_ENABLED_STATE_DEFAULT else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }

        /** Whether [intent] is ShotDrop being opened by a card. */
        fun isCard(intent: Intent?) =
            intent?.getBooleanExtra(EXTRA_CARD, false) == true ||
                intent?.action == "android.hardware.usb.action.USB_DEVICE_ATTACHED"
    }
}
