import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Instagram stories are 9:16, 1080 x 1920.
const storySize = Size(1080, 1920);

/// [photo] laid out as a story: full width over a blurred, darkened, enlarged
/// copy of itself, so a 4:5 or landscape photo isn't cut off. A photo already
/// as tall as 9:16 (or taller) just fills the frame.
Future<ui.Image> renderStory(ui.Image photo) =>
    renderFramed(photo, storySize, fill: photo.width / photo.height <= storySize.aspectRatio + 0.01);

/// [photo] in a frame of [size]: cut to fill it ([fill]; [anchorY] 0 keeps
/// the top, 0.5 the middle), or whole, centred over a blurred, darkened,
/// enlarged copy of itself.
Future<ui.Image> renderFramed(ui.Image photo, Size size, {required bool fill, double anchorY = 0.5}) {
  final src = Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble());
  final frame = Offset.zero & size;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..filterQuality = FilterQuality.high;

  if (fill) {
    canvas.drawImageRect(photo, src, coverRect(src.size, frame, anchorY: anchorY), paint);
  } else {
    // Background: the photo again, blown up to cover the frame and blurred.
    final blur = size.longestSide / 32;
    canvas.saveLayer(
      frame,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
    );
    canvas.drawImageRect(photo, src, coverRect(src.size, frame).inflate(blur * 2), paint);
    canvas.restore();
    canvas.drawRect(frame, Paint()..color = const Color(0x59000000));
    // Foreground: the whole photo, as big as fits, centred.
    final s = math.min(size.width / src.width, size.height / src.height);
    final fg = Rect.fromCenter(center: frame.center, width: src.width * s, height: src.height * s);
    canvas.drawRect(
      fg.shift(Offset(0, blur * 0.3)).inflate(blur * 0.1),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2),
    );
    canvas.drawImageRect(photo, src, fg, paint);
  }
  return recorder.endRecording().toImage(size.width.round(), size.height.round());
}

/// [content] scaled to cover [frame], centred across and placed [anchorY] of
/// the way down what's cut off (0 keeps the top).
Rect coverRect(Size content, Rect frame, {double anchorY = 0.5}) {
  final s = math.max(frame.width / content.width, frame.height / content.height);
  final cw = content.width * s, ch = content.height * s;
  return Rect.fromLTWH(frame.left + (frame.width - cw) / 2, frame.top + (frame.height - ch) * anchorY, cw, ch);
}
