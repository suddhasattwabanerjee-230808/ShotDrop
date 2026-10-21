import 'dart:math' as math;
import 'dart:ui';

/// Crop-frame geometry, all in normalized photo coordinates (0..1 each way).

const minCropSide = 0.08;

/// The normalized height-per-width that gives a frame of [ratio] (pixel
/// width / height) on a photo of [photo] pixels; null when the ratio is free.
double? normalizedRatio(Size photo, double? ratio) => ratio == null ? null : photo.width / (photo.height * ratio);

/// The frame after dragging corner [corner] (0 top-left, 1 top-right,
/// 2 bottom-right, 3 bottom-left) by [delta]. The opposite corner stays put;
/// [k] (from [normalizedRatio]) locks the shape.
Rect resizeCrop(Rect crop, int corner, Offset delta, double? k) {
  final anchor = switch (corner) {
    0 => crop.bottomRight,
    1 => crop.bottomLeft,
    2 => crop.topLeft,
    _ => crop.topRight,
  };
  final moving =
      switch (corner) {
        0 => crop.topLeft,
        1 => crop.topRight,
        2 => crop.bottomRight,
        _ => crop.bottomLeft,
      } +
      delta;
  final sx = corner == 1 || corner == 2 ? 1.0 : -1.0; // which way the frame grows from the anchor
  final sy = corner >= 2 ? 1.0 : -1.0;
  final roomX = sx > 0 ? 1 - anchor.dx : anchor.dx;
  final roomY = sy > 0 ? 1 - anchor.dy : anchor.dy;

  var w = ((moving.dx - anchor.dx) * sx).clamp(minCropSide, roomX);
  var h = ((moving.dy - anchor.dy) * sy).clamp(minCropSide, roomY);
  if (k != null) {
    // Follow whichever way the finger moved further, then fit inside the photo.
    if (delta.dy.abs() > delta.dx.abs()) w = math.max(h / k, minCropSide);
    h = w * k;
    if (h > roomY) {
      h = roomY;
      w = h / k;
    }
    if (w > roomX) {
      w = roomX;
      h = w * k;
    }
  }
  final left = sx > 0 ? anchor.dx : anchor.dx - w;
  final top = sy > 0 ? anchor.dy : anchor.dy - h;
  return Rect.fromLTWH(left, top, w, h);
}

/// The frame slid by [delta], kept inside the photo.
Rect moveCrop(Rect crop, Offset delta) {
  final left = (crop.left + delta.dx).clamp(0.0, 1 - crop.width);
  final top = (crop.top + delta.dy).clamp(0.0, 1 - crop.height);
  return Rect.fromLTWH(left, top, crop.width, crop.height);
}

/// Pixel aspect ratio (width / height) of [crop] on a photo of [photo] pixels.
double cropAspect(Rect crop, Size photo) => crop.width * photo.width / (crop.height * photo.height);

/// Instagram feed posts must be between 4:5 portrait and 1.91:1 landscape.
bool fitsFeed(double aspect) => aspect >= 0.8 - 0.005 && aspect <= 1.91 + 0.005;

/// The largest frame of [k] centred on the old frame's centre.
Rect refitCrop(Rect crop, double? k) {
  if (k == null) return crop;
  final c = crop.center;
  var w = math.max(crop.width, crop.height / k);
  var h = w * k;
  if (h > 1) {
    h = 1;
    w = h / k;
  }
  if (w > 1) {
    w = 1;
    h = w * k;
  }
  final left = (c.dx - w / 2).clamp(0.0, 1 - w);
  final top = (c.dy - h / 2).clamp(0.0, 1 - h);
  return Rect.fromLTWH(left, top, w, h);
}
