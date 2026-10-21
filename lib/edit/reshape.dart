import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'body.dart';

/// Stretch, as Cymera does it: the band [start]..[end] gets longer
/// ([amount] > 0) and the photo grows by [growth] to make room, so nothing
/// outside the band changes size. [map] gives positions as 0..1 of the grown
/// photo. The band edges fade in over [feather], so there's no visible seam.
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
    growth = sum / _steps;
  }

  final double start, end, amount, feather;
  static const _steps = 512;
  final _table = Float64List(_steps + 1);

  /// Height of the stretched photo over the original's.
  late final double growth;

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
/// stretched down by [yWarp] and moved by the [local] warps (all in
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
    for (var c = 0; c <= cols; c++) {
      final u = c / cols;
      var x = u, y = v;
      // The frame's edges stay put, so nothing pulls in from outside it.
      for (final w in local) {
        if (c > 0 && c < cols) x += w.dx(u, v);
        if (r > 0 && r < rows) y += w.dy(u, v);
      }
      positions[k] = x.clamp(0.0, 1.0) * outSize.width;
      positions[k + 1] = yWarp.map(y.clamp(0.0, 1.0)) * outSize.height;
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

/// The Slim, Hip and Legs warps an edit asks for. Legs slides each leg in
/// towards the other, closing the gap at the knees (straighter legs).
List<LocalWarp> bodyWarps(double slim, double hips, double legs, BodyAnchors body) {
  final mid = body.legs.map((l) => l.cx).reduce((a, b) => a + b) / body.legs.length;
  return [
    if (slim > 0) LocalWarp(body.waist, slim * maxSlim),
    if (hips > 0) LocalWarp(body.hips, hips * maxHips, lift: hips * maxHipLift),
    if (legs > 0)
      for (final leg in body.legs) LocalWarp(leg, 0, shift: legs * maxLegs * (mid - leg.cx).sign),
  ];
}
