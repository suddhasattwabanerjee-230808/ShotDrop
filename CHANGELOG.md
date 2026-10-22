# Changelog

## [0.5.3] - 2026-10-22 (build 9)

Opens again.

- Fixed: 0.5.2 stopped at a black screen. Settings are now saved by Android itself, not by an add-on that didn't work in the installed app (which is also why nothing was being remembered before).
- If something goes wrong while ShotDrop starts, it opens anyway and leaves a note in Download.

## [0.5.2] - 2026-10-22 (build 8)

Fixes, and tidier words.

- **Edits stay together.** Moving a Body slider no longer wipes the filter and adjustments (on the phone they vanished as soon as a slider left 0, and wouldn't have been saved either). The Crop page now shows the photo as it'll be saved, slimmed and filtered, inside the frame.
- **Settings are remembered.** The welcome page shows on the first start only, your Instagram username is kept, and so are the card folder and every setting. They were being lost on each restart.
- **Unplugging the card** empties the Gallery straight away and shows "Plug In Your Camera Card" again.
- **Upload folder:** swipe right to move a photo to Selected, swipe left to delete it from the Upload folder (Undo to bring it back). "Select All" / "Deselect All".
- Every button, title and label is in Title Case.
- The Instagram logo marks your account in Settings.

## [0.5.1] - 2026-10-22 (build 7)

Opens again.

- Fixed: ShotDrop closed as soon as it opened (since 0.4). A part of the photo tools that starts with the app was being trimmed out of the release build.

## [0.5.0] - 2026-10-22 (build 6)

Four tabs, and a shortlist.

- A rounded bar floats at the bottom: **Gallery** (the card), **Selected**, **Upload** and **Settings**. Counts show on Selected and Upload; a dot on Settings when there's an update.
- **Selected** is your shortlist. Tap ♡ on a photo in the viewer, or long-press a few in the Gallery and tap "To Selected". ShotDrop copies them off the card, so they're there with the card unplugged. Tap one to edit it into the Upload folder.
- Photos in the Upload folder that you don't post go back to Selected afterwards, edits and all, ready for next time. Swiping one away in the Upload folder sets it aside in Selected too.
- If ShotDrop closes by itself, it leaves a note in Download (ShotDrop-crash-….txt) saying why, so it can be fixed.
- **Settings**: your Instagram account and caption auto-paste; the card folder; start portrait photos at 4:5; saved size (2160 or 1080 px); copy edits to the gallery; what Publish starts on; space used, and clearing posted copies and thumbnails; updates.

## [0.4.1] - 2026-10-22 (build 5)

A much smaller download.

- The APK is about a third of the size: it no longer carries code for kinds of phone it never runs on, and what it carries is compressed.
- Nothing else changes.

## [0.4.0] - 2026-10-22 (build 4)

Slim like Cymera's, and a smoother day-to-day.

**Card**
- Opens on the card's photos. The Instagram setup shows on the very first launch only, however you leave it.
- Plug in the card and its photos come up by themselves. A card used before opens straight away; a new card shows "Card found", and one tap opens the picker right on its DCIM folder (Android asks once per card).
- "Choose another folder" (⋮ menu) now really switches the grid to that folder. Rescanning updates it too.

**Editing**
- Crop, Body and Adjust are always there together: go from Slim straight to a filter or the crop and back, nothing to Apply first. Changes show as you make them; undo covers them all.
- **Slim**: tap Slim and pick the area, a line with a bracket at each end ("Select the waist area."). ShotDrop finds the body by itself (on the phone, offline) and starts the line on the waist with the brackets on the body's edges. Tap ✓, then slide: each bracket pushes its side of the body in (or out, for wider), as Cymera does. Earlier areas can be tapped and changed again, moved, or removed; "New area" adds another.
- **Stretch** goes both ways: taller or shorter.
- Re-cropping keeps Slim's areas and Stretch's lines on the same part of the body.
- Photos slimmed in 0.3.0 keep their Slim, as a line across the waist.

**Upload folder**
- Tick the photos to publish; unticked ones stay for later. Only the published ones leave the folder.
- Each photo has an Edit button (tapping the photo works too) to change its edit again from the original.

**Instagram**
- Caption auto-paste: switch on "ShotDrop caption paste" once (⋮ menu > Caption auto-paste walks you through it) and ShotDrop types the caption into Instagram's caption box itself. Off, it's copied for pasting as before.
- The "Added to the Upload folder" note now goes away after 3 seconds.

**Updates**
- ⋮ menu > Update app: checks for a new version, shows what's new, downloads it and opens Android's installer. A dot on the menu says when one is out.

## [0.3.0] - 2026-10-21 (build 3)

Body tools, Cymera-style.

- The Body tab has four tools, each opened on its own with a 0–100 slider and Cancel / Apply: **Stretch** (longer legs, taller look), **Slim** (draws the waist in), **Hip** (fuller hips), **Legs** (slimmer legs).
- ShotDrop finds the person in the photo by itself (on the phone, offline) and puts each tool in the right place: the waist for Slim, the hips for Hip, each leg for Legs, and Stretch's two lines from the hips to the ankles.
- Each tool's area shows as a dashed circle you can drag if it's off, or if no person is found.
- Replaces the old Taller/Shorter and Thinner/Wider sliders.

## [0.2.0] - 2026-10-21 (build 2)

Publishing.

- Publish from the Upload folder as **Post only**, **Post + Story** or **Story only**. ShotDrop opens Instagram's own post or story screen with the photos loaded, and you tap Share. Several photos become one carousel (10 at most per post).
- Story versions are made for you: 9:16, the photo at full width over a blurred copy of itself.
- The caption is copied when Instagram opens: long-press the caption box and tap Paste.
- A step-by-step screen: open Instagram, come back, say whether it posted. Posted photos leave the Upload folder, show POSTED in the grid, and their gallery copies move to Pictures/ShotDrop/Published.
- Facebook: Instagram can share every post and story to your Facebook profile by itself (Accounts Center). Or ShotDrop can open Facebook for each post too.
- New Instagram & Facebook screen, shown once on first launch and from the Upload folder: checks the apps are installed, remembers your username, and walks through turning on sharing to Facebook.

## [0.1.0] - 2026-10-21 (build 1)

First build: card to Upload folder.

- Reads the D5600's SD card over USB OTG (pick the card's DCIM folder once; it opens by itself when the card is plugged in).
- Grid of every shot by day, JPG and NEF paired into one tile with a RAW badge; long-press to pick several.
- Full-screen viewer: swipe through the card, pinch or double-tap to zoom.
- "Edit before upload": crop (4:5, 1:1, 1.91:1, 9:16, free), rotate, flip, straighten; body reshape (taller / shorter, thinner / wider) with draggable bands; filters and brightness / contrast / saturation / warmth; undo / redo and hold to compare.
- Upload folder: edited photos in posting order (drag to reorder, swipe to remove with undo, tap to edit again from the original), caption, and a copy in Pictures/ShotDrop/Upload.
- Posting to Instagram comes next.
