import 'dart:math' as math;
import 'dart:typed_data';

import 'body.dart';

/// Slim: pick a stretch of the body with a line and two brackets (Cymera's
/// "Select the waist area"), then each bracket pushes its side of the body
/// in towards the other (or out, for wider). Each push covers a circle
/// centred on its bracket, a little more than half as wide as the line is
/// long, so the two overlap in the middle; nothing outside them moves.
/// Size, falloff and strength were fitted to a screen recording of Cymera.
class SlimArea {
  const SlimArea(this.y, this.left, this.right, [this.amount = 0]);
  final double y; // the line's height, 0..1 down the cropped photo
  final double left, right; // the brackets, 0..1 across
  final double amount; // -1 (wider) .. 1 (slimmest)

  double get span => (right - left).abs();

  SlimArea copyWith({double? y, double? left, double? right, double? amount}) =>
      SlimArea(y ?? this.y, left ?? this.left, right ?? this.right, amount ?? this.amount);

  /// How far the point at normalized ([u], [v]) moves across, in a photo
  /// [aspect] (width / height) wide.
  double dx(double u, double v, double aspect) {
    if (amount == 0 || span < 0.01) return 0;
    final r = span / 2 * slimReach, push = amount * maxSlimPush * span;
    final dv = (v - y) / aspect; // in widths, so the circles are round
    var d = 0.0;
    for (final (cx, sign) in [(math.min(left, right), 1.0), (math.max(left, right), -1.0)]) {
      final t2 = ((u - cx) * (u - cx) + dv * dv) / (r * r);
      if (t2 < 1) d += sign * push * (1 - t2) * (1 - t2);
    }
    return d;
  }

  List<double> toJson() => [y, left, right, amount];
  static SlimArea? fromJson(Object? j) {
    final l = [for (final v in (j as List? ?? const [])) (v as num).toDouble()];
    return l.length == 4 ? SlimArea(l[0], l[1], l[2], l[3]) : null;
  }
}

/// How far a bracket moves at 1 on the slider, as a share of the line's
/// length; never enough for the photo to fold over.
const maxSlimPush = 0.085;

/// Each push's radius, in half-lines.
const slimReach = 1.3;

/// The person's outline: [w] x [h] cells over the cropped photo, 0..255
/// (255 = certainly the person).
class BodyMask {
  BodyMask(this.w, this.h, this.data) : assert(data.length == w * h);
  final int w, h;
  final Uint8List data;

  /// A [w] x [h] mask shrunk so its long edge is at most [maxEdge] cells,
  /// each cell the mean of the pixels it covers.
  factory BodyMask.fit(int w, int h, Uint8List src, {int maxEdge = 256}) {
    final k = math.min(1.0, maxEdge / math.max(w, h));
    final ow = math.max(1, (w * k).round()), oh = math.max(1, (h * k).round());
    if (ow == w && oh == h) return BodyMask(w, h, src);
    final out = Uint8List(ow * oh);
    for (var y = 0; y < oh; y++) {
      final y0 = y * h ~/ oh, y1 = math.max(y0 + 1, (y + 1) * h ~/ oh);
      for (var x = 0; x < ow; x++) {
        final x0 = x * w ~/ ow, x1 = math.max(x0 + 1, (x + 1) * w ~/ ow);
        var sum = 0;
        for (var yy = y0; yy < y1; yy++) {
          for (var xx = x0; xx < x1; xx++) {
            sum += src[yy * w + xx];
          }
        }
        out[y * ow + x] = sum ~/ ((y1 - y0) * (x1 - x0));
      }
    }
    return BodyMask(ow, oh, out);
  }

  bool at(int x, int y) => data[y * w + x] >= 128;

  /// The body's left and right edges (0..1) on the row at [y], in the run of
  /// body nearest [x]; null if there's no body on that row.
  (double, double)? edgesAt(double y, double x) {
    final row = (y * h).floor().clamp(0, h - 1);
    final cx = (x * w).floor().clamp(0, w - 1);
    (int, int)? best;
    var bestGap = w + 1;
    for (var i = 0; i < w;) {
      if (!at(i, row)) {
        i++;
        continue;
      }
      final from = i;
      while (i < w && at(i, row)) {
        i++;
      }
      final gap = cx < from ? from - cx : (cx >= i ? cx - i + 1 : 0);
      if (i - from >= 2 && gap < bestGap) {
        bestGap = gap;
        best = (from, i);
      }
    }
    return best == null ? null : (best.$1 / w, best.$2 / w);
  }
}

/// Where Slim's line starts: across the waist, brackets on the body's edges
/// (from the outline when there is one, else from the pose, else a guess).
SlimArea placeSlim(BodyAnchors body, BodyMask? mask) {
  final waist = body.waist;
  final edges = mask?.edgesAt(waist.cy, waist.cx);
  if (edges != null && edges.$2 - edges.$1 > 0.04) return SlimArea(waist.cy, edges.$1, edges.$2);
  return SlimArea(waist.cy, (waist.cx - waist.rx * 0.6).clamp(0.0, 1.0), (waist.cx + waist.rx * 0.6).clamp(0.0, 1.0));
}
