# ShotDrop

Camera card → phone → Instagram. Plug the Nikon D5600's SD card into the phone
over OTG, pick photos, edit them ("Edit before upload": crop, rotate, body
reshape, filters) into the Upload folder, then hand them to Instagram as a
post, a story, or both.

Android only, Flutter. The SD card is read through the Storage Access Framework
in `android/app/src/main/kotlin/com/bittu/shotdrop/CardChannel.kt`; everything
else is Dart under `lib/`.

- `flutter analyze && flutter test` — checks and unit tests.
- `flutter test test/preview_test.dart --dart-define=PREVIEW_DIR=/some/dir` —
  renders the main screens to PNGs with fake card data.
- APKs build in CI (`.github/workflows`); push a `v*.*.*` tag for a release.
