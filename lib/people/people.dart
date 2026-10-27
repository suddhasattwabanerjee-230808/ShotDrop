import 'dart:math' as math;
import 'dart:typed_data';

import '../edit/erase.dart' show distanceTo;

/// Finding the people in a photo, picking who it's of, and outlining the rest
/// for removal. Plain functions over pixel buffers, so they run in isolates and
/// in tests; the models themselves run in [OrtRunner] (see remove_people.dart).
///
/// - Finder: YOLOX-S (Apache 2.0, OpenCV Zoo, int8), COCO's "person" class.
///   Run on the whole photo and on overlapping tiles, so people far off in the
///   background are big enough to be found.
/// - Outliner: PP-HumanSeg (Apache 2.0, OpenCV Zoo), on a crop around each
///   person, kept to that person's own box and their own blob, since the crop
///   shows neighbours too.

/// An RGBA photo.
class Photo {
  const Photo(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

/// A pixel rectangle, right and bottom exclusive.
class Box {
  const Box(this.l, this.t, this.r, this.b);
  final int l, t, r, b;
  int get w => r - l;
  int get h => b - t;
  Box clampTo(int width, int height) =>
      Box(l.clamp(0, width), t.clamp(0, height), r.clamp(0, width), b.clamp(0, height));
  Box grow(int dx, int dy) => Box(l - dx, t - dy, r + dx, b + dy);
  @override
  String toString() => 'Box($l, $t, $r, $b)';
}

/// A person the finder saw: where (in photo pixels, fractional) and how sure.
class Found {
  const Found(this.x0, this.y0, this.x1, this.y1, this.score);
  final double x0, y0, x1, y1, score;
  double get w => x1 - x0;
  double get h => y1 - y0;
  double get area => math.max(0, w) * math.max(0, h);
  Box box(int width, int height) => Box(x0.floor(), y0.floor(), x1.ceil(), y1.ceil()).clampTo(width, height);
  @override
  String toString() => 'Found(${x0.round()}, ${y0.round()}, ${x1.round()}, ${y1.round()}, ${score.toStringAsFixed(2)})';
}

// ─── Finder ──────────────────────────────────────────────────────────────

const finderSize = 640;

/// Lowest finder score taken as a person.
const minPersonScore = 0.3;

/// Where to run the finder on a [width] x [height] photo: the whole photo,
/// then 2x2 overlapping tiles, and 3x3 on big photos, so a person far off is
/// big enough in some tile to be found.
List<Box> finderRegions(int width, int height) {
  final out = [Box(0, 0, width, height)];
  for (final n in math.max(width, height) >= 1400 ? const [2, 3] : const [2]) {
    final tw = math.min(width, (width / n * 1.25).round()), th = math.min(height, (height / n * 1.25).round());
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final x = ((width - tw) * i / (n - 1)).round(), y = ((height - th) * j / (n - 1)).round();
        out.add(Box(x, y, x + tw, y + th));
      }
    }
  }
  return out;
}

/// The finder's input for [region] of [photo]: shrunk to fit 640 x 640 at
/// the top left, the rest grey (114), as blue, green, red planes of 0..255.
/// Also returns the scale used.
(Float32List, double) finderInput(Photo photo, Box region) {
  const s = finderSize;
  final r = math.min(s / region.w, s / region.h);
  final nw = math.min(s, (region.w * r).floor()), nh = math.min(s, (region.h * r).floor());
  final out = Float32List(3 * s * s)..fillRange(0, 3 * s * s, 114);
  final sample = _Bilinear(photo, region, nw, nh);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      sample.at(x, y);
      final o = y * s + x;
      out[o] = sample.b;
      out[s * s + o] = sample.g;
      out[2 * s * s + o] = sample.r;
    }
  }
  return (out, r);
}

/// The people in the finder's output for [region] of a [width] x [height]
/// photo, shrunk by [scale], in photo pixels. [out] is 8400 rows of 85:
/// centre, size (log), objectness, then 80 class scores (person first).
/// Someone cut off by the edge of a tile (not the photo's edge) is left to the
/// whole-photo pass or another tile: a tile only sees part of them, and its
/// box would be part of a person.
List<Found> finderPeople(
  Float32List out,
  double scale,
  Box region,
  int width,
  int height, {
  double minScore = minPersonScore,
}) {
  final x0 = region.l, y0 = region.t;
  final edge = 0.015 * math.max(region.w, region.h);
  const s = finderSize, row = 85;
  final found = <Found>[];
  var i = 0;
  for (final stride in const [8, 16, 32]) {
    final n = s ~/ stride;
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++, i++) {
        final o = i * row;
        final score = out[o + 4] * out[o + 5];
        if (score < minScore) continue;
        final cx = (out[o] + gx) * stride, cy = (out[o + 1] + gy) * stride;
        final w = math.exp(out[o + 2]) * stride, h = math.exp(out[o + 3]) * stride;
        final f = Found(
          (cx - w / 2) / scale + x0,
          (cy - h / 2) / scale + y0,
          (cx + w / 2) / scale + x0,
          (cy + h / 2) / scale + y0,
          score,
        );
        if ((region.l > 0 && f.x0 < region.l + edge) ||
            (region.t > 0 && f.y0 < region.t + edge) ||
            (region.r < width && f.x1 > region.r - edge) ||
            (region.b < height && f.y1 > region.b - edge)) {
          continue;
        }
        found.add(f);
      }
    }
  }
  return found;
}

/// One box per person: the surest first (the bigger of two equally sure); a
/// box overlapping a kept one by more than half (IoU), or lying mostly
/// inside it, goes.
List<Found> onePerPerson(List<Found> all) {
  final sorted = [...all]
    ..sort((a, b) {
      final s = (b.score * 100).round().compareTo((a.score * 100).round());
      return s != 0 ? s : b.area.compareTo(a.area);
    });
  final kept = <Found>[];
  outer:
  for (final f in sorted) {
    for (final k in kept) {
      final ix = math.max(0.0, math.min(f.x1, k.x1) - math.max(f.x0, k.x0));
      final iy = math.max(0.0, math.min(f.y1, k.y1) - math.max(f.y0, k.y0));
      final inter = ix * iy;
      if (inter <= 0) continue;
      final iou = inter / (f.area + k.area - inter);
      if (iou >= 0.5 || inter / math.min(f.area, k.area) >= 0.8) continue outer;
    }
    kept.add(f);
  }
  return kept;
}

// ─── Who stays ───────────────────────────────────────────────────────────

/// A main subject must be at least this tall, as a share of the photo's
/// height; with nobody that big (a landscape with passers-by), everyone goes.
const minMainHeight = 0.10;

/// Which of [people] (in a [width] x [height] photo) the photo is of: the
/// main subject (big, sure, near the middle) and anyone posing with them:
/// nearly as tall as the subject, and standing right beside the subject or
/// beside someone else posing (a row of friends). Indexes into [people];
/// empty if nobody is big enough to be the subject.
Set<int> whoStays(List<Found> people, int width, int height) {
  if (people.isEmpty) return {};
  var main = -1;
  var best = 0.0;
  for (var i = 0; i < people.length; i++) {
    final p = people[i];
    final cx = (p.x0 + p.x1) / 2 / width;
    final rank = p.area * p.score * (1.2 - (cx - 0.5).abs());
    if (rank > best) {
      best = rank;
      main = i;
    }
  }
  if (main < 0 || people[main].h < minMainHeight * height) return {};
  final keep = {main};
  final subject = people[main];
  for (var grew = true; grew;) {
    grew = false;
    for (var i = 0; i < people.length; i++) {
      if (keep.contains(i)) continue;
      final p = people[i];
      for (final k in keep.toList()) {
        final q = people[k];
        final gap = math.max(0.0, math.max(q.x0 - p.x1, p.x0 - q.x1));
        if (p.h >= 0.65 * subject.h && gap <= 0.35 * subject.w) {
          keep.add(i);
          grew = true;
          break;
        }
      }
    }
  }
  return keep;
}

// ─── Outliner ────────────────────────────────────────────────────────────

const outlinerSize = 192;

/// The crop the outliner looks at for [person]: their box and a little more.
Box outlinerCrop(Found person, int width, int height) => Box(
  (person.x0 - person.w * 0.15).floor(),
  (person.y0 - person.h * 0.1).floor(),
  (person.x1 + person.w * 0.15).ceil(),
  (person.y1 + person.h * 0.1).ceil(),
).clampTo(width, height);

/// The outliner's input for [crop] of [photo]: 192 x 192, red, green, blue
/// planes in -1..1.
Float32List outlinerInput(Photo photo, Box crop) {
  const s = outlinerSize;
  final out = Float32List(3 * s * s);
  final sample = _Bilinear(photo, crop, s, s);
  for (var y = 0; y < s; y++) {
    for (var x = 0; x < s; x++) {
      sample.at(x, y);
      final o = y * s + x;
      out[o] = sample.r / 127.5 - 1;
      out[s * s + o] = sample.g / 127.5 - 1;
      out[2 * s * s + o] = sample.b / 127.5 - 1;
    }
  }
  return out;
}

/// A person's outline: 0..255 over [box] of the photo.
class Outline {
  const Outline(this.box, this.alpha);
  final Box box;
  final Uint8List alpha;
}

/// [person]'s outline from the outliner's output for [crop] ([out]: two
/// 192 x 192 planes, background and person scores). Only what's inside
/// their own box (a little margin) and joined to their biggest blob counts.
Outline outlineOf(Found person, Box crop, Float32List out, int width, int height) {
  const s = outlinerSize;
  final box = Box(
    (person.x0 - person.w * 0.06).floor(),
    (person.y0 - person.h * 0.04).floor(),
    (person.x1 + person.w * 0.06).ceil(),
    (person.y1 + person.h * 0.04).ceil(),
  ).clampTo(width, height);
  final bw = box.w, bh = box.h;
  final prob = Float32List(math.max(0, bw * bh));
  if (prob.isEmpty || crop.w <= 0 || crop.h <= 0) return Outline(box, Uint8List(prob.length));
  // Person probability (softmax of the two scores), sampled back over the box.
  final plane = Float32List(s * s);
  for (var i = 0; i < s * s; i++) {
    plane[i] = 1 / (1 + math.exp(out[i] - out[s * s + i]));
  }
  for (var y = 0; y < bh; y++) {
    final sy = ((box.t + y + 0.5 - crop.t) * s / crop.h - 0.5).clamp(0.0, s - 1.0);
    final y0 = sy.floor(), y1 = math.min(y0 + 1, s - 1), fy = sy - y0;
    for (var x = 0; x < bw; x++) {
      final sx = ((box.l + x + 0.5 - crop.l) * s / crop.w - 0.5).clamp(0.0, s - 1.0);
      final x0 = sx.floor(), x1 = math.min(x0 + 1, s - 1), fx = sx - x0;
      final a = plane[y0 * s + x0], b = plane[y0 * s + x1], c = plane[y1 * s + x0], d = plane[y1 * s + x1];
      prob[y * bw + x] = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
    }
  }
  // Their own blob: the biggest 4-connected one above 0.4.
  final label = Int32List(bw * bh);
  var bestLabel = 0, bestSize = 0, next = 0;
  final stack = <int>[];
  for (var i = 0; i < label.length; i++) {
    if (prob[i] <= 0.4 || label[i] != 0) continue;
    next++;
    var size = 0;
    label[i] = next;
    stack.add(i);
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      size++;
      final x = j % bw, y = j ~/ bw;
      for (final k in [if (x > 0) j - 1, if (x < bw - 1) j + 1, if (y > 0) j - bw, if (y < bh - 1) j + bw]) {
        if (label[k] == 0 && prob[k] > 0.4) {
          label[k] = next;
          stack.add(k);
        }
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = next;
    }
  }
  // Keep the soft edge: anything within 3 px of the blob keeps its probability.
  final blob = Uint8List(bw * bh);
  for (var i = 0; i < blob.length; i++) {
    if (bestLabel != 0 && label[i] == bestLabel) blob[i] = 1;
  }
  final near = distanceTo(bw, bh, blob);
  final alpha = Uint8List(bw * bh);
  for (var i = 0; i < alpha.length; i++) {
    if (near[i] <= 3) alpha[i] = (prob[i] * 255).round().clamp(0, 255);
  }
  return Outline(box, alpha);
}

// ─── Masks ───────────────────────────────────────────────────────────────

/// What to do with a photo's people: [remove] (255 = rebuild this pixel) and
/// [keep] (255 = the people staying, never touched or copied), each
/// width x height; [removed] and [kept] count them.
class PeopleMasks {
  const PeopleMasks(this.remove, this.keep, this.removed, this.kept);
  final Uint8List remove, keep;
  final int removed, kept;
}

/// The masks for [outlines] of [people] in a [width] x [height] photo, where
/// [stays] are the ones kept.
///
/// Where two outlines overlap (someone standing behind the subject: each
/// crop sees both), a pixel belongs to whoever's box it sits nearer the
/// middle of (across counting fully, up and down by half: a face is at the
/// top of its box), but someone being removed only takes it from someone
/// staying when under half as far, so the subject's own arms and hair are
/// never cut.
/// Each person removed is grown by 3% of their height (at least [minGrow]
/// px), so their edge, hair and motion blur go too: a little background too
/// many is filled in anyway, a sliver of someone left is a ghost. The people
/// kept are grown by 2 px and win wherever the two meet.
PeopleMasks peopleMasks(
  List<Found> people,
  List<Outline> outlines,
  Set<int> stays,
  int width,
  int height, {
  int minGrow = 4,
}) {
  final n = width * height;
  final owner = Int16List(n)..fillRange(0, n, -1);
  final ownerNear = Float32List(n);
  for (var i = 0; i < people.length; i++) {
    final o = outlines[i], p = people[i];
    final cx = (p.x0 + p.x1) / 2, cy = (p.y0 + p.y1) / 2;
    final hw = math.max(1.0, p.w / 2), hh = math.max(1.0, p.h / 2);
    final staying = stays.contains(i);
    for (var y = 0; y < o.box.h; y++) {
      for (var x = 0; x < o.box.w; x++) {
        if (o.alpha[y * o.box.w + x] < 77) continue;
        final px = o.box.l + x, py = o.box.t + y, j = py * width + px;
        final near = math.max((px + 0.5 - cx).abs() / hw, 0.5 * (py + 0.5 - cy).abs() / hh);
        final had = owner[j];
        if (had >= 0) {
          final hadStays = stays.contains(had);
          if (hadStays == staying) continue; // same side: same mask either way
          final win = staying ? near * 0.5 <= ownerNear[j] : near < 0.5 * ownerNear[j];
          if (!win) continue;
        }
        owner[j] = i;
        ownerNear[j] = near;
      }
    }
  }
  final remove = Uint8List(n), keep = Uint8List(n);
  for (var i = 0; i < people.length; i++) {
    final staying = stays.contains(i);
    final o = outlines[i];
    final grow = staying ? 2 : math.max(minGrow, (people[i].h * 0.03).round());
    final box = o.box.grow(grow + 1, grow + 1).clampTo(width, height);
    if (box.w <= 0 || box.h <= 0) continue;
    final seeds = Uint8List(box.w * box.h);
    for (var y = 0; y < o.box.h; y++) {
      for (var x = 0; x < o.box.w; x++) {
        if (owner[(o.box.t + y) * width + o.box.l + x] == i) {
          seeds[(o.box.t + y - box.t) * box.w + o.box.l + x - box.l] = 1;
        }
      }
    }
    final d = distanceTo(box.w, box.h, seeds);
    final target = staying ? keep : remove;
    for (var y = 0; y < box.h; y++) {
      for (var x = 0; x < box.w; x++) {
        if (d[y * box.w + x] <= grow) target[(box.t + y) * width + box.l + x] = 255;
      }
    }
  }
  for (var i = 0; i < n; i++) {
    if (keep[i] != 0) remove[i] = 0;
  }
  return PeopleMasks(remove, keep, people.length - stays.length, stays.length);
}

// ─── Sampling ────────────────────────────────────────────────────────────

/// Samples [region] of a photo as if scaled to [ow] x [oh] (bilinear,
/// pixel centres), into [r], [g], [b].
class _Bilinear {
  _Bilinear(this.photo, this.region, int ow, int oh) : kx = region.w / ow, ky = region.h / oh;
  final Photo photo;
  final Box region;
  final double kx, ky;
  double r = 0, g = 0, b = 0;

  void at(int x, int y) {
    final w = photo.width, px = photo.rgba;
    final sx = (region.l + (x + 0.5) * kx - 0.5).clamp(0.0, w - 1.0);
    final sy = (region.t + (y + 0.5) * ky - 0.5).clamp(0.0, photo.height - 1.0);
    final x0 = sx.floor(), y0 = sy.floor();
    final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, photo.height - 1);
    final fx = sx - x0, fy = sy - y0;
    final i00 = (y0 * w + x0) * 4, i01 = (y0 * w + x1) * 4, i10 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4;
    double mix(int k) {
      final top = px[i00 + k] + (px[i01 + k] - px[i00 + k]) * fx;
      final bottom = px[i10 + k] + (px[i11 + k] - px[i10 + k]) * fx;
      return top + (bottom - top) * fy;
    }

    r = mix(0);
    g = mix(1);
    b = mix(2);
  }
}

/// [photo]'s [region] scaled to [ow] x [oh] (bilinear), RGB 0..1 planes.
Float32List planes01(Photo photo, Box region, int ow, int oh) {
  final out = Float32List(3 * ow * oh);
  final sample = _Bilinear(photo, region, ow, oh);
  final n = ow * oh;
  for (var y = 0; y < oh; y++) {
    for (var x = 0; x < ow; x++) {
      sample.at(x, y);
      final o = y * ow + x;
      out[o] = sample.r / 255;
      out[n + o] = sample.g / 255;
      out[2 * n + o] = sample.b / 255;
    }
  }
  return out;
}
