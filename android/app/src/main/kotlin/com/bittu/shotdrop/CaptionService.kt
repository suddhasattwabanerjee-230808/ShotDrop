package com.bittu.shotdrop

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Types the Upload folder's caption into Instagram's caption box. Instagram
 * ignores captions handed over with a share, so this is the only way: when
 * ShotDrop opens Instagram's new-post screen it leaves the caption here, and
 * as soon as the caption box shows up (empty) it's filled in, once.
 *
 * It also makes sure the photos arrive: Instagram, started from cold (closed
 * by Android after a while unused), opens on its home feed and drops what it
 * was handed. If the feed shows up in the first seconds after a share instead
 * of the new-post screen, the share is sent again, now that Instagram's up.
 *
 * It only ever looks at Instagram, and only while a caption or share is waiting.
 */
class CaptionService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.packageName?.toString() != ShareChannel.INSTAGRAM) return
        if (watch == null && pending(this) == null) return
        val root = rootInActiveWindow ?: return
        checkShare(root)
        fillCaption(root)
    }

    /** The share just sent: done once a new-post screen shows; sent again if the feed shows instead. */
    private fun checkShare(root: AccessibilityNodeInfo) {
        val w = watch ?: return
        val age = System.currentTimeMillis() - w.at
        if (age > WATCH_MS || any(root, 0, ::isComposer)) {
            watch = null
            return
        }
        if (age < RETRY_AFTER_MS || !any(root, 0, ::isFeed)) return
        if (w.tries >= MAX_TRIES) {
            watch = null
            return
        }
        watch = w.copy(tries = w.tries + 1, at = System.currentTimeMillis())
        runCatching { startActivity(Intent(w.intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    /** Instagram's tab bar, which only the main screens (feed, search, profile) have. */
    private fun isFeed(n: AccessibilityNodeInfo): Boolean {
        val id = n.viewIdResourceName.orEmpty()
        return id.endsWith("/tab_bar") || id.endsWith("/feed_tab") || id.endsWith("/profile_tab")
    }

    /** A new-post or story screen: its Next button, its caption box, or its title. */
    private fun isComposer(n: AccessibilityNodeInfo): Boolean {
        val words = listOf(n.text?.toString(), n.contentDescription?.toString()).mapNotNull { it?.trim()?.lowercase() }
        return words.any { it == "next" || it == "new post" || it == "your story" } ||
            (n.isEditable && "caption" in n.viewIdResourceName.orEmpty().lowercase())
    }

    private fun any(node: AccessibilityNodeInfo, depth: Int, test: (AccessibilityNodeInfo) -> Boolean): Boolean {
        if (depth > 40) return false
        if (test(node)) return true
        for (i in 0 until node.childCount) {
            if (node.getChild(i)?.let { any(it, depth + 1, test) } == true) return true
        }
        return false
    }

    private fun fillCaption(root: AccessibilityNodeInfo) {
        val caption = pending(this) ?: return
        val box = find(root, 0) ?: return
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
        private data class Watch(val intent: Intent, val at: Long, val tries: Int = 0)

        private const val WATCH_MS = 15_000L // a share is watched this long after it's sent (or re-sent)
        private const val RETRY_AFTER_MS = 2_500L // give Instagram this long to get to the new post
        private const val MAX_TRIES = 2

        @Volatile private var watch: Watch? = null

        /** Watches the share [intent] just sent to Instagram (see the class comment). */
        fun watchShare(intent: Intent) {
            watch = Watch(Intent(intent), System.currentTimeMillis())
        }

        /** Back in ShotDrop: stop watching. */
        fun stopWatching() {
            watch = null
        }

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
