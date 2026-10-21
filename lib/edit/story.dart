import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Instagram stories are 9:16, 1080 x 1920.
const storySize = Size(1080, 1920);

/// [photo] laid out as a story: full width over a blurred, darkened, enlarged
/// copy of itself, so a 4:5 or landscape photo isn't cut off. A photo already
/// as tall as 9:16 (or taller) just fills the frame.
Future<ui.Image> renderStory(ui.Image photo) {
  final w = storySize.width, h = storySize.height;
  final src = Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble());
  final frame = Offset.zero & storySize;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..filterQuality = FilterQuality.high;

  if (src.width / src.height <= w / h + 0.01) {
    canvas.drawImageRect(photo, src, _cover(src.size, frame), paint);
  } else {
    // Background: the photo again, blown up to cover the frame and blurred.
    canvas.saveLayer(
      frame,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.clamp),
    );
    canvas.drawImageRect(photo, src, _cover(src.size, frame).inflate(120), paint);
    canvas.restore();
    canvas.drawRect(frame, Paint()..color = const Color(0x59000000));
    // Foreground: the photo at full width, centred.
    final fh = w * src.height / src.width;
    final fg = Rect.fromLTWH(0, (h - fh) / 2, w, fh);
    canvas.drawRect(
      fg.shift(const Offset(0, 18)).inflate(6),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );
    canvas.drawImageRect(photo, src, fg, paint);
  }
  return recorder.endRecording().toImage(w.toInt(), h.toInt());
}

Rect _cover(Size content, Rect frame) {
  final s = math.max(frame.width / content.width, frame.height / content.height);
  final cw = content.width * s, ch = content.height * s;
  return Rect.fromLTWH(frame.left + (frame.width - cw) / 2, frame.top + (frame.height - ch) / 2, cw, ch);
}
