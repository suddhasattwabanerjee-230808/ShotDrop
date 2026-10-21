import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'body.dart';

/// A smooth, monotonic remap of 0..1 onto 0..1 that makes the band
/// [start]..[end] longer ([amount] > 0) or shorter ([amount] < 0) and spreads
/// the opposite change over the rest of the line, so the ends stay put.
///
/// This is how "taller / thinner" works: the person's band is stretched or
/// squeezed and the background around them gives up or takes the slack. The
/// band edges fade in over [feather], so there's no visible seam.
class BandWarp {
  BandWarp(double start, double end, this.amount, {this.feather = 0.06})
    : start = math.min(start, end).clamp(0.0, 1.0),
      end = math.max(start, end).clamp(0.0, 1.0) {
    // Cumulative density table; map() interpolates it.
    final density = [for (var i = 0; i <= _steps; i++) 1 + amount.clamp(-0.9, 2.0) * _window(i / _steps)];
    var sum = 0.0;
    _table[0] = 0;
    for (var i = 1; i <= _steps; i++) {
      sum += (density[i - 1] + density[i]) / 2;
      _table[i] = sum;
    }
    for (var i = 1; i <= _steps; i++) {
      _table[i] /= sum;
    }
  }

  final double start, end, amount, feather;
  static const _steps = 512;
  final _table = Float64List(_steps + 1);

  bool get isIdentity => amount.abs() < 1e-4 || end - start < 1e-4;

  double _window(double t) =>
      _smooth(start - feather, start + feather, t) * (1 - _smooth(end - feather, end + feather, t));

  static double _smooth(double a, double b, double t) {
    final x = ((t - a) / (b - a)).clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  /// Where source position [t] (0..1) lands in the output.
  double map(double t) {
    if (isIdentity) return t;
    final x = t.clamp(0.0, 1.0) * _steps;
    final i = x.floor().clamp(0, _steps - 1);
    final f = x - i;
    return _table[i] + (_table[i + 1] - _table[i]) * f;
  }

  /// The source position that lands at output position [y]; the inverse of [map].
  double unmap(double y) {
    if (isIdentity) return y;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      if (map(mid) < y) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }
}

/// A textured triangle mesh that draws a [srcSize] image into [outSize],
/// stretched down by [yWarp] and pushed across by the [local] warps (all in
/// normalized coordinates of the image). Draw it with a Paint whose shader is
/// an ImageShader of the image (texture coordinates are in image pixels).
Vertices buildWarpMesh(
  Size srcSize,
  Size outSize,
  BandWarp yWarp, {
  List<LocalWarp> local = const [],
  int cols = 64,
  int rows = 64,
}) {
  final positions = Float32List((cols + 1) * (rows + 1) * 2);
  final tex = Float32List((cols + 1) * (rows + 1) * 2);
  var k = 0;
  for (var r = 0; r <= rows; r++) {
    final v = r / rows;
    final y = yWarp.map(v) * outSize.height;
    for (var c = 0; c <= cols; c++) {
      final u = c / cols;
      var x = u;
      // The frame's edges stay put, so nothing pulls in from outside it.
      if (c > 0 && c < cols) {
        for (final w in local) {
          x += w.dx(u, v);
        }
      }
      positions[k] = x.clamp(0.0, 1.0) * outSize.width;
      positions[k + 1] = y;
      tex[k] = u * srcSize.width;
      tex[k + 1] = v * srcSize.height;
      k += 2;
    }
  }
  final indices = Uint16List(cols * rows * 6);
  var n = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final a = r * (cols + 1) + c;
      final b = a + 1;
      final d = a + cols + 1;
      final e = d + 1;
      indices
        ..[n++] = a
        ..[n++] = b
        ..[n++] = d
        ..[n++] = b
        ..[n++] = e
        ..[n++] = d;
    }
  }
  return Vertices.raw(VertexMode.triangles, positions, textureCoordinates: tex, indices: indices);
}

/// The Slim, Hip and Legs warps an edit asks for.
List<LocalWarp> bodyWarps(double slim, double hips, double legs, BodyAnchors body) => [
  if (slim > 0) LocalWarp(body.waist, slim * maxSlim),
  if (hips > 0) LocalWarp(body.hips, hips * maxHips),
  if (legs > 0)
    for (final leg in body.legs) LocalWarp(leg, legs * maxLegs),
];
