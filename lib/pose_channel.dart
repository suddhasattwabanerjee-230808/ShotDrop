import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'edit/body.dart';
import 'edit/shape.dart';

/// What the phone found in a photo: the pose (null when no person is
/// clearly visible) and the person's outline (null if segmentation failed).
typedef BodyScan = ({BodyAnchors? body, BodyMask? mask});

/// Finds the person in a photo (PoseChannel.kt, ML Kit, on the phone).
class PoseChannel {
  PoseChannel._();
  static final instance = PoseChannel._();

  static const _m = MethodChannel('shotdrop/pose');

  /// The person in [image]. The photo is shrunk first: neither pose
  /// detection nor the outline needs the detail.
  Future<BodyScan> detect(ui.Image image) async {
    const maxEdge = 720;
    final k = math.min(1.0, maxEdge / math.max(image.width, image.height));
    final w = math.max(1, (image.width * k).round()), h = math.max(1, (image.height * k).round());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final small = await recorder.endRecording().toImage(w, h);
    final rgba = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    small.dispose();
    final r = await _m.invokeMapMethod<Object?, Object?>('detect', {
      'rgba': rgba!.buffer.asUint8List(),
      'width': w,
      'height': h,
    });
    final landmarks = <int, (double, double, double)>{
      for (final e in (r?['landmarks'] as Map? ?? const {}).entries)
        if (e.key is int && e.value is List && (e.value as List).length == 3)
          e.key as int: (
            ((e.value as List)[0] as num).toDouble(),
            ((e.value as List)[1] as num).toDouble(),
            ((e.value as List)[2] as num).toDouble(),
          ),
    };
    final mask = r?['mask'], mw = r?['maskWidth'], mh = r?['maskHeight'];
    return (
      body: BodyAnchors.fromLandmarks(landmarks),
      mask: mask is Uint8List && mw is int && mh is int && mask.length == mw * mh ? BodyMask.fit(mw, mh, mask) : null,
    );
  }
}
