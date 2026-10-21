import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models.dart';
import 'filters.dart';
import 'reshape.dart';

/// The edit pipeline, shared by the editor's live preview and the export:
///   rotate / flip → straighten (zoomed so no corners show) → crop
///   → body reshape → colour filter.
/// Everything is drawn on a Canvas, so the preview is exactly what gets saved.

/// Size of the photo after quarter turns.
Size orientedSize(Size src, EditParams p) => p.isOriented ? Size(src.height, src.width) : src;

/// Zoom needed so a photo of [size] rotated by [degrees] still covers its own frame.
double straightenScale(Size size, double degrees) {
  final a = (degrees * math.pi / 180).abs();
  final c = math.cos(a), s = math.sin(a);
  return math.max(c + s * size.height / size.width, c + s * size.width / size.height);
}

/// Draws [src] rotated, flipped and straightened into the rect (0, 0, [o]).
void paintOriented(Canvas canvas, ui.Image src, EditParams p, Size o) {
  final w = src.width.toDouble(), h = src.height.toDouble();
  canvas.save();
  canvas.translate(o.width / 2, o.height / 2);
  if (p.straighten != 0) {
    canvas.rotate(p.straighten * math.pi / 180);
    final s = straightenScale(o, p.straighten);
    canvas.scale(s, s);
  }
  if (p.flipH) canvas.scale(-1, 1);
  canvas.rotate(p.quarterTurns * math.pi / 2);
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, w, h),
    Rect.fromLTWH(-w / 2, -h / 2, w, h),
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
}

/// Pixel size of the cropped photo, scaled down so the long edge is at most [maxEdge].
Size croppedSize(Size src, EditParams p, {int? maxEdge}) {
  final o = orientedSize(src, p);
  var w = p.crop.width * o.width, h = p.crop.height * o.height;
  if (maxEdge != null) {
    final k = math.min(1.0, maxEdge / math.max(w, h));
    w *= k;
    h *= k;
  }
  return Size(w.roundToDouble().clamp(1, 1e5), h.roundToDouble().clamp(1, 1e5));
}

/// Rotate, straighten and crop [src] into a new image.
Future<ui.Image> renderCropped(ui.Image src, EditParams p, {int? maxEdge}) {
  final srcSize = Size(src.width.toDouble(), src.height.toDouble());
  final o = orientedSize(srcSize, p);
  final out = croppedSize(srcSize, p, maxEdge: maxEdge);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & out, Paint()..color = const Color(0xFF000000));
  canvas.scale(out.width / (p.crop.width * o.width), out.height / (p.crop.height * o.height));
  canvas.translate(-p.crop.left * o.width, -p.crop.top * o.height);
  paintOriented(canvas, src, p, o);
  return recorder.endRecording().toImage(out.width.toInt(), out.height.toInt());
}

/// Draws the cropped photo into [out] with the body reshape and colour filter.
void paintFinish(Canvas canvas, ui.Image cropped, Size out, EditParams p, {bool colour = true}) {
  final matrix = matrixFor(p);
  final paint = Paint()..filterQuality = FilterQuality.high;
  if (colour && !isIdentity(matrix)) paint.colorFilter = ColorFilter.matrix(matrix);
  final src = Size(cropped.width.toDouble(), cropped.height.toDouble());
  final yWarp = BandWarp(p.heightBand.$1, p.heightBand.$2, p.height);
  final local = bodyWarps(p.slim, p.hips, p.legs, p.bodyOrDefault);
  if (yWarp.isIdentity && local.isEmpty) {
    canvas.drawImageRect(cropped, Offset.zero & src, Offset.zero & out, paint);
    return;
  }
  paint.shader = ImageShader(cropped, TileMode.clamp, TileMode.clamp, _identity4, filterQuality: FilterQuality.high);
  canvas.drawVertices(buildWarpMesh(src, out, yWarp, local: local), BlendMode.srcOver, paint);
}

final _identity4 = Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

/// The finished photo, at most [maxEdge] pixels on its long side.
Future<ui.Image> renderFinal(ui.Image src, EditParams p, {int maxEdge = 2160}) async {
  final cropped = await renderCropped(src, p, maxEdge: maxEdge);
  final out = Size(cropped.width.toDouble(), cropped.height.toDouble());
  final recorder = ui.PictureRecorder();
  paintFinish(Canvas(recorder), cropped, out, p);
  final image = await recorder.endRecording().toImage(cropped.width, cropped.height);
  cropped.dispose();
  return image;
}

/// A centred crop rect of [ratio] (width / height) in a photo of [o], as large as fits.
Rect centeredCrop(Size o, double? ratio) {
  if (ratio == null) return const Rect.fromLTWH(0, 0, 1, 1);
  final photo = o.width / o.height;
  if (ratio > photo) {
    final h = photo / ratio;
    return Rect.fromLTWH(0, (1 - h) / 2, 1, h);
  }
  final w = ratio / photo;
  return Rect.fromLTWH((1 - w) / 2, 0, w, 1);
}

/// [content] scaled to fit [box] less [pad] all round, with [top] kept clear
/// (for controls floating over the photo).
Rect fitRect(Size content, Size box, {double pad = 20, double top = 0}) {
  final avail = Size(math.max(1, box.width - pad * 2), math.max(1, box.height - pad * 2 - top));
  final s = math.min(avail.width / content.width, avail.height / content.height);
  final w = content.width * s, h = content.height * s;
  return Rect.fromLTWH((box.width - w) / 2, top + (box.height - top - h) / 2, w, h);
}
