import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../edit/erase.dart';
import 'ort.dart';
import 'people.dart';

/// Remove People From Background: one tap keeps who the photo is of and
/// rebuilds the background where everyone else stood.
///
///  1. Find everyone (people.dart) with the photo turned upright, outline
///     them, and pick who stays (the main subject and anyone posing with them).
///  2. LaMa (Apache 2.0, OpenCV Zoo) paints what's behind the others, one
///     area at a time, from a 512 x 512 view of the area and what's around it.
///     It knows how walls, railings and buildings carry on, but paints soft.
///  3. The eraser (edit/erase.dart) redraws LaMa's picture out of real pixels
///     from the same photo, so the fill is as sharp and grainy as the rest,
///     never touching or copying the people who stay.

/// The three model files, downloaded once (model_store.dart).
class PeopleModels {
  const PeopleModels({required this.finder, required this.outliner, required this.painter});
  final String finder, outliner, painter;
}

enum RemoveStage { finding, painting, finishing }

/// What [removePeople] did: the photo with the people gone ([photo], same
/// size), where it changed ([changed], 0..255 a pixel), and how many people
/// went and stayed.
class RemoveResult {
  const RemoveResult(this.photo, this.changed, this.removed, this.kept);
  final Photo photo;
  final Uint8List changed;
  final int removed, kept;
}

/// LaMa's fixed input size.
const painterSize = 512;

/// [photo] with everyone but its subject removed. [quarterTurns] (clockwise)
/// turn the photo upright for finding people, as the editor will show it.
/// [onFound] hears who was found (boxes in the upright photo, [w] x [h]) and
/// who stays, before the slow part; [onProgress] gets the stage and 0..1
/// overall.
Future<RemoveResult> removePeople(
  Photo photo,
  OrtRunner ort,
  PeopleModels models, {
  int quarterTurns = 0,
  void Function(List<Found> people, Set<int> stays, int w, int h)? onFound,
  void Function(RemoveStage stage, double progress)? onProgress,
}) async {
  final turns = quarterTurns % 4;
  final upright = turns == 0 ? photo : await _turnPhoto(photo, turns);
  final w = upright.width, h = upright.height;

  // 1. Everyone in it.
  onProgress?.call(RemoveStage.finding, 0);
  final regions = finderRegions(w, h);
  final found = <Found>[];
  for (var i = 0; i < regions.length; i++) {
    final region = regions[i];
    final (input, scale) = finderInput(upright, region);
    final out = await ort.run(models.finder, [
      Tensor.f32('images', const [1, 3, finderSize, finderSize], input),
    ]);
    found.addAll(finderPeople(out.first.floats, scale, region, w, h));
    onProgress?.call(RemoveStage.finding, 0.15 * (i + 1) / regions.length);
  }
  final people = onePerPerson(found);
  final stays = whoStays(people, w, h);
  onFound?.call(people, stays, w, h);
  if (people.length == stays.length) {
    onProgress?.call(RemoveStage.finishing, 1);
    return RemoveResult(photo, Uint8List(photo.width * photo.height), 0, stays.length);
  }

  final outlines = <Outline>[];
  for (var i = 0; i < people.length; i++) {
    final person = people[i];
    final crop = outlinerCrop(person, w, h);
    final out = await ort.run(models.outliner, [
      Tensor.f32('x', const [1, 3, outlinerSize, outlinerSize], outlinerInput(upright, crop)),
    ]);
    final scores = out.first.floats;
    outlines.add(await _outlineOf(person, crop, scores, w, h));
    onProgress?.call(RemoveStage.finding, 0.15 + 0.1 * (i + 1) / people.length);
  }
  final masks = await _peopleMasks(people, outlines, stays, w, h);

  // 2. LaMa's picture of what's behind them, area by area.
  final hole = await _grownMask(masks.remove, masks.keep, w, h, 3);
  final areas = paintAreas(hole, w, h);
  final guide = Uint8List.fromList(upright.rgba);
  var guideScale = 1;
  for (var i = 0; i < areas.length; i++) {
    final area = areas[i];
    final (image, mask) = painterInput(upright, hole, area);
    final out = await ort.run(models.painter, [
      Tensor.f32('image', const [1, 3, painterSize, painterSize], image),
      Tensor.f32('mask', const [1, 1, painterSize, painterSize], mask),
    ]);
    final painted = out.first.floats;
    final pasted = await _pastePainted(Photo(w, h, guide), hole, area, painted);
    guide.setAll(0, pasted);
    guideScale = math.max(guideScale, (math.max(area.w, area.h) / painterSize).ceil());
    onProgress?.call(RemoveStage.painting, 0.25 + 0.45 * (i + 1) / areas.length);
  }
  ort.close().catchError((Object _) {}); // the models take a few hundred MB loaded

  // 3. The same, in the photo's own pixels.
  final job = EraseJob(
    width: w,
    height: h,
    rgba: upright.rgba,
    mask: masks.remove,
    protect: masks.keep,
    guide: guide,
    guideScale: guideScale,
    grow: 3,
    feather: 3,
  );
  final rgba = await eraseObjects(job, onProgress: (p) => onProgress?.call(RemoveStage.finishing, 0.7 + 0.3 * p));
  var result = Photo(w, h, rgba);
  var changed = hole;
  if (turns != 0) {
    final back = (4 - turns) % 4;
    result = await _turnPhoto(result, back);
    changed = await _turnPlane(hole, w, h, back);
  }
  return RemoveResult(result, changed, masks.removed, masks.kept);
}

// Off the UI isolate. Each starts its isolate from here, where the closure
// can only take its own arguments: one made inside removePeople would carry
// removePeople's whole scope along, onProgress (and the screen it calls
// back to) included, which can't be sent to another isolate.
Future<Photo> _turnPhoto(Photo p, int turns) => Isolate.run(() => turnPhoto(p, turns));
Future<Uint8List> _turnPlane(Uint8List m, int w, int h, int turns) => Isolate.run(() => turnPlane(m, w, h, turns));
Future<Outline> _outlineOf(Found p, Box crop, Float32List scores, int w, int h) =>
    Isolate.run(() => outlineOf(p, crop, scores, w, h));
Future<PeopleMasks> _peopleMasks(List<Found> people, List<Outline> outlines, Set<int> stays, int w, int h) =>
    Isolate.run(() => peopleMasks(people, outlines, stays, w, h));
Future<Uint8List> _grownMask(Uint8List remove, Uint8List keep, int w, int h, int grow) =>
    Isolate.run(() => grownMask(remove, keep, w, h, grow));

/// [mergeInto], off the UI isolate.
Future<Uint8List> mergeIntoInBackground(Photo full, RemoveResult result) => Isolate.run(() => mergeInto(full, result));
Future<Uint8List> _pastePainted(Photo photo, Uint8List hole, Box area, Float32List painted) =>
    Isolate.run(() => pastePainted(photo, hole, area, painted));

/// [remove] grown by [grow] px, minus [keep] (both width x height, 255 = set).
Uint8List grownMask(Uint8List remove, Uint8List keep, int width, int height, int grow) {
  final d = distanceTo(width, height, remove);
  final out = Uint8List(width * height);
  for (var i = 0; i < out.length; i++) {
    if (d[i] <= grow && keep[i] == 0) out[i] = 255;
  }
  return out;
}

/// The areas LaMa paints, one per cluster of [hole]: its bounds and 30% of
/// its size on every side (at least 32 px), so LaMa sees what's around it
/// but not so much that a big subject nearby crowds into the picture.
List<Box> paintAreas(Uint8List hole, int width, int height) {
  const c = 8;
  final gw = (width + c - 1) ~/ c, gh = (height + c - 1) ~/ c;
  final cell = Uint8List(gw * gh);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (hole[y * width + x] != 0) cell[(y ~/ c) * gw + x ~/ c] = 1;
    }
  }
  var areas = <Box>[];
  final stack = <int>[];
  for (var i = 0; i < cell.length; i++) {
    if (cell[i] != 1) continue;
    var l = gw, t = gh, r = 0, b = 0;
    cell[i] = 2;
    stack.add(i);
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      final x = j % gw, y = j ~/ gw;
      l = math.min(l, x);
      t = math.min(t, y);
      r = math.max(r, x + 1);
      b = math.max(b, y + 1);
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= gw || ny >= gh || cell[ny * gw + nx] != 1) continue;
          cell[ny * gw + nx] = 2;
          stack.add(ny * gw + nx);
        }
      }
    }
    final box = Box(l * c, t * c, r * c, b * c).clampTo(width, height);
    final m = math.max(32, (math.max(box.w, box.h) * 0.3).round());
    areas.add(box.grow(m, m).clampTo(width, height));
  }
  // Areas that overlap are painted as one, so neither paints over the
  // other's edge; so are neighbours whose joint area is hardly bigger (a
  // queue of people: one LaMa run instead of one each, at ~7 s a run).
  bool join(Box a, Box b) {
    if (a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b) return true;
    final u = _union(a, b);
    return u.w * u.h <= 1.6 * (a.w * a.h + b.w * b.h) &&
        math.max(u.w, u.h) <= math.max(1100, math.max(math.max(a.w, a.h), math.max(b.w, b.h)));
  }

  for (var merged = true; merged;) {
    merged = false;
    final out = <Box>[];
    for (final a in areas) {
      final i = out.indexWhere((o) => join(o, a));
      if (i < 0) {
        out.add(a);
        continue;
      }
      out[i] = _union(out[i], a);
      merged = true;
    }
    areas = out;
  }
  return areas;
}

Box _union(Box a, Box b) => Box(math.min(a.l, b.l), math.min(a.t, b.t), math.max(a.r, b.r), math.max(a.b, b.b));

/// LaMa's inputs for [area]: the picture (512 x 512, RGB 0..1) and the hole
/// (1 wherever any of [hole] falls in a cell).
(Float32List, Float32List) painterInput(Photo photo, Uint8List hole, Box area) {
  const s = painterSize;
  final image = planes01(photo, area, s, s);
  final mask = Float32List(s * s);
  for (var y = 0; y < s; y++) {
    final y0 = area.t + y * area.h ~/ s, y1 = math.max(y0 + 1, area.t + (y + 1) * area.h ~/ s);
    for (var x = 0; x < s; x++) {
      final x0 = area.l + x * area.w ~/ s, x1 = math.max(x0 + 1, area.l + (x + 1) * area.w ~/ s);
      search:
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          if (hole[yy * photo.width + xx] != 0) {
            mask[y * s + x] = 1;
            break search;
          }
        }
      }
    }
  }
  return (image, mask);
}

/// [photo]'s pixels with LaMa's [painted] picture of [area] (3 planes of
/// 512 x 512, 0..255) scaled back up into its [hole] pixels.
Uint8List pastePainted(Photo photo, Uint8List hole, Box area, Float32List painted) {
  const s = painterSize;
  final out = Uint8List.fromList(photo.rgba);
  final w = photo.width;
  for (var y = area.t; y < area.b; y++) {
    final sy = ((y - area.t + 0.5) * s / area.h - 0.5).clamp(0.0, s - 1.0);
    final y0 = sy.floor(), y1 = math.min(y0 + 1, s - 1), fy = sy - y0;
    for (var x = area.l; x < area.r; x++) {
      if (hole[y * w + x] == 0) continue;
      final sx = ((x - area.l + 0.5) * s / area.w - 0.5).clamp(0.0, s - 1.0);
      final x0 = sx.floor(), x1 = math.min(x0 + 1, s - 1), fx = sx - x0;
      for (var k = 0; k < 3; k++) {
        final p = k * s * s;
        final a = painted[p + y0 * s + x0], b = painted[p + y0 * s + x1];
        final c = painted[p + y1 * s + x0], d = painted[p + y1 * s + x1];
        final v = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
        out[(y * w + x) * 4 + k] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// [photo] turned [turns] quarter turns clockwise.
Photo turnPhoto(Photo photo, int turns) {
  final w = photo.width, h = photo.height;
  final t = turns % 4;
  if (t == 0) return photo;
  final ow = t.isOdd ? h : w, oh = t.isOdd ? w : h;
  final src = photo.rgba.buffer.asUint32List(photo.rgba.offsetInBytes, w * h);
  final dst = Uint32List(ow * oh);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (nx, ny) = switch (t) {
        1 => (h - 1 - y, x),
        2 => (w - 1 - x, h - 1 - y),
        _ => (y, w - 1 - x),
      };
      dst[ny * ow + nx] = src[y * w + x];
    }
  }
  return Photo(ow, oh, dst.buffer.asUint8List());
}

/// One byte a pixel version of [turnPhoto].
Uint8List turnPlane(Uint8List plane, int w, int h, int turns) {
  final t = turns % 4;
  if (t == 0) return plane;
  final ow = t.isOdd ? h : w;
  final dst = Uint8List(plane.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (nx, ny) = switch (t) {
        1 => (h - 1 - y, x),
        2 => (w - 1 - x, h - 1 - y),
        _ => (y, w - 1 - x),
      };
      dst[ny * ow + nx] = plane[y * w + x];
    }
  }
  return dst;
}

/// [full] (the original, any size) with [result]'s changed pixels scaled up
/// into it, blended by [RemoveResult.changed]; everything else stays
/// full-resolution.
Uint8List mergeInto(Photo full, RemoveResult result) {
  final out = Uint8List.fromList(full.rgba);
  final sw = result.photo.width, sh = result.photo.height, src = result.photo.rgba, m = result.changed;
  final kx = sw / full.width, ky = sh / full.height;
  for (var y = 0; y < full.height; y++) {
    final sy = ((y + 0.5) * ky - 0.5).clamp(0.0, sh - 1.0);
    final y0 = sy.floor(), y1 = math.min(y0 + 1, sh - 1), fy = sy - y0;
    for (var x = 0; x < full.width; x++) {
      final sx = ((x + 0.5) * kx - 0.5).clamp(0.0, sw - 1.0);
      final x0 = sx.floor(), x1 = math.min(x0 + 1, sw - 1), fx = sx - x0;
      final i00 = y0 * sw + x0, i01 = y0 * sw + x1, i10 = y1 * sw + x0, i11 = y1 * sw + x1;
      final a = ((m[i00] + (m[i01] - m[i00]) * fx) * (1 - fy) + (m[i10] + (m[i11] - m[i10]) * fx) * fy) / 255;
      if (a <= 0) continue;
      final o = (y * full.width + x) * 4;
      for (var k = 0; k < 3; k++) {
        final v =
            (src[i00 * 4 + k] + (src[i01 * 4 + k] - src[i00 * 4 + k]) * fx) * (1 - fy) +
            (src[i10 * 4 + k] + (src[i11 * 4 + k] - src[i10 * 4 + k]) * fx) * fy;
        out[o + k] = (out[o + k] + (v - out[o + k]) * a).round().clamp(0, 255);
      }
    }
  }
  return out;
}
