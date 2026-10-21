# Changelog

## [0.4.0] - 2026-10-22 (build 4)

Slim, the way Cymera does it.

- Tap **Slim** and pick the area: a line with a bracket at each end ("Select the waist area."). ShotDrop finds the body by itself (on the phone, offline) and starts the line on the waist with the brackets on the body's edges. Drag the line up or down and the brackets follow the body; drag a bracket to set it yourself. Tap ✓.
- Then slide: each bracket pushes its side of the body in (or out, for wider), fading out in a circle so the face and background further away don't move. Tuned against a screen recording of Cymera to give the same result.
- Tap Slim again to pick another area on top.
- **Stretch** now goes both ways: taller or shorter.
- The Body screen is laid out like Cymera's: the slider (with its value, like +0.55) over the row of tools, and Cancel / Body / Apply for everything changed since you opened it. Tools switch without closing.
- Photos slimmed in 0.3.0 keep their Slim, as a line across the waist.

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
