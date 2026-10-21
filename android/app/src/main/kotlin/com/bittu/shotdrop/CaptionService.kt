package com.bittu.shotdrop

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Types the Upload folder's caption into Instagram's caption box. Instagram
 * ignores captions handed over with a share, so this is the only way: when
 * ShotDrop opens Instagram's new-post screen it leaves the caption here, and
 * as soon as the caption box shows up (empty) it's filled in, once. It only
 * ever looks at Instagram, and only while a caption is waiting.
 */
class CaptionService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.packageName?.toString() != ShareChannel.INSTAGRAM) return
        val caption = pending(this) ?: return
        val box = rootInActiveWindow?.let { find(it, 0) } ?: return
        val text = box.text?.toString().orEmpty()
        val hint = if (Build.VERSION.SDK_INT >= 26) box.hintText?.toString().orEmpty() else ""
        // Something's typed there already: leave it alone.
        if (text.isNotEmpty() && text != hint && !looksLikeHint(text)) {
            clear(this)
            return
        }
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, caption)
        }
        if (box.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) clear(this)
    }

    override fun onInterrupt() {}

    /** Instagram's caption box: editable, and named or labelled as the caption. */
    private fun find(node: AccessibilityNodeInfo, depth: Int): AccessibilityNodeInfo? {
        if (depth > 40) return null
        if (node.isEditable) {
            val id = node.viewIdResourceName.orEmpty().lowercase()
            val hint = if (Build.VERSION.SDK_INT >= 26) node.hintText?.toString().orEmpty() else ""
            val label = listOf(hint, node.text?.toString().orEmpty(), node.contentDescription?.toString().orEmpty())
            if ("caption" in id || label.any { looksLikeHint(it) }) return node
        }
        for (i in 0 until node.childCount) {
            val found = node.getChild(i)?.let { find(it, depth + 1) }
            if (found != null) return found
        }
        return null
    }

    private fun looksLikeHint(s: String) = s.length < 60 && "caption" in s.lowercase()

    companion object {
        private const val PREFS = "shotdrop.caption"
        private const val MAX_AGE_MS = 15 * 60 * 1000L

        /** Leaves [caption] for the next Instagram caption box (for 15 minutes). */
        fun setPending(context: Context, caption: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("text", caption)
                .putLong("at", System.currentTimeMillis())
                .apply()
        }

        private fun pending(context: Context): String? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val text = prefs.getString("text", null) ?: return null
            if (System.currentTimeMillis() - prefs.getLong("at", 0) > MAX_AGE_MS) {
                clear(context)
                return null
            }
            return text
        }

        private fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }

        /** Whether it's switched on in Settings > Accessibility. */
        fun isOn(context: Context): Boolean {
            val on = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
                ?: return false
            val me = ComponentName(context, CaptionService::class.java)
            return on.split(':').any {
                it.equals(me.flattenToString(), true) || it.equals(me.flattenToShortString(), true)
            }
        }
    }
}
