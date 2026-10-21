# Changelog

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
