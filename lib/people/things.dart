import 'dart:math' as math;
import 'dart:typed_data';

import '../edit/erase.dart' show distanceTo;
import 'people.dart';

/// Finding the things that don't belong in a photo (vehicles, bins, cones,
/// bags left lying about, stray animals), outlining them and picking which
/// go, next to the people (people.dart). Plain functions over pixel buffers,
/// like people.dart, so they run in isolates and in tests.
///
/// - Thing finder: D-FINE-S (Apache 2.0) trained on Objects365, 365 kinds of
///   thing; only [unwantedKinds] are looked for. Run on the whole photo and
///   on 2 x 2 tiles, so a bin down the street is big enough to be found.
/// - Outliner: MobileSAM (Apache 2.0), which outlines whatever's in a box:
///   the photo is looked at once, then each thing is outlined from its box.

/// Something found that isn't a person: a person's box and score, and which
/// kind of thing it is.
class Thing extends Found {
  const Thing(super.x0, super.y0, super.x1, super.y1, super.score, this.kind);
  final String kind;
  @override
  String toString() => '$kind(${x0.round()}, ${y0.round()}, ${x1.round()}, ${y1.round()}, ${score.toStringAsFixed(2)})';
}

// ─── Finder ──────────────────────────────────────────────────────────────

const thingFinderSize = 640;

/// The finder's classes.
const thingClasses = 366;

/// Lowest finder score taken as a thing.
const minThingScore = 0.4;

/// What's removed, by the finder's class: things that were added to the
/// scene rather than built into it. Not what people wear (hats, glasses,
/// shoes: they go with their person), not what's part of the place (seats,
/// tables, lamps, signs, trees), nothing too big to rebuild.
const unwantedKinds = {
  6: 'Car',
  14: 'Bag',
  21: 'Box',
  35: 'Car', // SUV
  39: 'Backpack',
  45: 'Bin',
  47: 'Bicycle',
  49: 'Barrel',
  50: 'Van',
  53: 'Basket',
  56: 'Bus',
  57: 'Bird',
  59: 'Motorbike',
  66: 'Truck',
  67: 'Cone',
  79: 'Horse',
  88: 'Truck', // pickup
  93: 'Dog',
  97: 'Cow',
  100: 'Sheep',
  110: 'Truck', // diggers and the like
  121: 'Suitcase',
  125: 'Trolley',
  127: 'Car', // sports car
  130: 'Scooter',
  131: 'Pram',
  137: 'Duck',
  140: 'Cat',
  158: 'Shovel',
  165: 'Pigeon',
  173: 'Ladder',
  177: 'Hydrant',
  184: 'Tricycle',
  189: 'Fire Engine',
  200: 'Truck', // heavy
  216: 'Cart',
  222: 'Chicken',
  242: 'Goose',
  249: 'Ambulance',
  250: 'Parking Meter',
  270: 'Broom',
  273: 'Rickshaw',
  301: 'Pig',
  308: 'Camel',
  309: 'Race Car',
  324: 'Donkey',
  336: 'Mop',
  342: 'Monkey',
  345: 'Yak',
};

/// Where to run the finder on a [width] x [height] photo: the whole photo,
/// then 2 x 2 overlapping tiles.
List<Box> thingRegions(int width, int height) {
  final out = [Box(0, 0, width, height)];
  final tw = math.min(width, (width / 2 * 1.25).round()), th = math.min(height, (height / 2 * 1.25).round());
  for (var j = 0; j < 2; j++) {
    for (var i = 0; i < 2; i++) {
      final x = (width - tw) * i, y = (height - th) * j;
      out.add(Box(x, y, x + tw, y + th));
    }
  }
  return out;
}

/// The finder's input for [region] of [photo]: stretched to 640 x 640, red,
/// green, blue planes in 0..1.
Float32List thingFinderInput(Photo photo, Box region) => planes01(photo, region, thingFinderSize, thingFinderSize);

/// The unwanted things in the finder's output for [region] of a
/// [width] x [height] photo, in photo pixels: [logits] (300 rows of a score
/// a class) and [boxes] (300 rows of centre and size, 0..1 of the region).
/// As with people, something cut off by a tile's edge is left to the
/// whole-photo pass or another tile.
List<Thing> finderThings(
  Float32List logits,
  Float32List boxes,
  Box region,
  int width,
  int height, {
  double minScore = minThingScore,
}) {
  final minLogit = math.log(minScore / (1 - minScore));
  final edge = 0.015 * math.max(region.w, region.h);
  final found = <Thing>[];
  for (var q = 0; q < boxes.length ~/ 4; q++) {
    final o = q * thingClasses;
    var best = 0;
    for (var c = 1; c < thingClasses; c++) {
      if (logits[o + c] > logits[o + best]) best = c;
    }
    final kind = unwantedKinds[best];
    if (kind == null || logits[o + best] < minLogit) continue;
    final cx = boxes[q * 4], cy = boxes[q * 4 + 1], w = boxes[q * 4 + 2], h = boxes[q * 4 + 3];
    final t = Thing(
      region.l + (cx - w / 2) * region.w,
      region.t + (cy - h / 2) * region.h,
      region.l + (cx + w / 2) * region.w,
      region.t + (cy + h / 2) * region.h,
      1 / (1 + math.exp(-logits[o + best])),
      kind,
    );
    if ((region.l > 0 && t.x0 < region.l + edge) ||
        (region.t > 0 && t.y0 < region.t + edge) ||
        (region.r < width && t.x1 > region.r - edge) ||
        (region.b < height && t.y1 > region.b - edge)) {
      continue;
    }
    found.add(t);
  }
  return found;
}

// ─── Outliner ────────────────────────────────────────────────────────────

/// The outliner looks at the photo with its long side this size.
const samSize = 1024;

/// It hands back each outline over the photo with its long side this size.
const samMaskSize = 256;

/// The outliner's look at [photo]: its long side 1024 px, as rows of red,
/// green, blue (0..255), and that size.
(Float32List, int, int) samInput(Photo photo) {
  final k = samSize / math.max(photo.width, photo.height);
  final w = math.max(1, (photo.width * k).round()), h = math.max(1, (photo.height * k).round());
  final planes = planes01(photo, Box(0, 0, photo.width, photo.height), w, h);
  final n = w * h;
  final out = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    out[i * 3] = planes[i] * 255;
    out[i * 3 + 1] = planes[n + i] * 255;
    out[i * 3 + 2] = planes[2 * n + i] * 255;
  }
  return (out, w, h);
}

/// The size the outliner hands outlines back at, for a [width] x [height]
/// photo: its long side [samMaskSize].
(int, int) samMaskSizeFor(int width, int height) {
  final k = samMaskSize / math.max(width, height);
  return (math.max(1, (width * k).round()), math.max(1, (height * k).round()));
}

/// [thing]'s box as the outliner's prompt: its corners in the outliner's
/// view of a [width] x [height] photo, and their labels (box corners).
(Float32List, Float32List) samPrompt(Found thing, int width, int height) {
  final k = samSize / math.max(width, height);
  return (Float32List.fromList([thing.x0 * k, thing.y0 * k, thing.x1 * k, thing.y1 * k]), Float32List.fromList([2, 3]));
}

/// [thing]'s outline from the outliner's [mask] scores (over the whole
/// photo, [mw] x [mh]), in a [width] x [height] photo: only what's in its
/// box (and a little more) counts, as the outliner may run on into what's
/// beside it. If it found next to nothing there, the whole box is taken.
Outline thingOutline(Found thing, Float32List mask, int mw, int mh, int width, int height) {
  final box = Box(
    (thing.x0 - math.max(3, thing.w * 0.04)).floor(),
    (thing.y0 - math.max(3, thing.h * 0.04)).floor(),
    (thing.x1 + math.max(3, thing.w * 0.04)).ceil(),
    (thing.y1 + math.max(3, thing.h * 0.04)).ceil(),
  ).clampTo(width, height);
  final bw = box.w, bh = box.h;
  final alpha = Uint8List(math.max(0, bw * bh));
  if (alpha.isEmpty) return Outline(box, alpha);
  final kx = mw / width, ky = mh / height;
  var on = 0;
  for (var y = 0; y < bh; y++) {
    final sy = ((box.t + y + 0.5) * ky - 0.5).clamp(0.0, mh - 1.0);
    final y0 = sy.floor(), y1 = math.min(y0 + 1, mh - 1), fy = sy - y0;
    for (var x = 0; x < bw; x++) {
      final sx = ((box.l + x + 0.5) * kx - 0.5).clamp(0.0, mw - 1.0);
      final x0 = sx.floor(), x1 = math.min(x0 + 1, mw - 1), fx = sx - x0;
      final a = mask[y0 * mw + x0], b = mask[y0 * mw + x1], c = mask[y1 * mw + x0], d = mask[y1 * mw + x1];
      final v = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
      final p = (255 / (1 + math.exp(-2 * v))).round();
      alpha[y * bw + x] = p;
      if (p >= 128) on++;
    }
  }
  if (on < 0.1 * thing.area) {
    final own = thing.box(width, height);
    alpha.fillRange(0, alpha.length, 0);
    for (var y = own.t; y < own.b; y++) {
      alpha.fillRange((y - box.t) * bw + own.l - box.l, (y - box.t) * bw + own.r - box.l, 255);
    }
  }
  return Outline(box, alpha);
}

// ─── Which stay ──────────────────────────────────────────────────────────

/// A thing bigger than this share of the photo stays: too much to rebuild.
const maxThingArea = 0.3;

/// Which of [things] (outlined by [outlines]) stay in a [width] x [height]
/// photo, given the [people] (outlined by [peopleOutlines]) and who of them
/// [stays]. Indexes into [things]; the rest go.
///
/// A thing stays when it's the subject's: it touches someone staying and
/// stands at their feet or in front of them (the bike they hold, the car
/// they lean on, the scooter they sit on), or it's small, held up against
/// them below their head (their bag). A thing too big to rebuild stays too.
/// With no one staying, the photo may be of a thing: the biggest, surest one
/// near the middle stays if it's a quarter of the photo's height or more.
Set<int> thingsStaying(
  List<Thing> things,
  List<Outline> outlines,
  List<Found> people,
  List<Outline> peopleOutlines,
  Set<int> stays,
  int width,
  int height,
) {
  final out = <int>{};
  for (var i = 0; i < things.length; i++) {
    final t = things[i];
    if (t.area > maxThingArea * width * height) {
      out.add(i);
      continue;
    }
    for (final s in stays) {
      final p = people[s];
      if (!_touches(outlines[i], peopleOutlines[s], math.max(4.0, 0.02 * p.h))) continue;
      final atFeet = t.y1 >= p.y1 - 0.15 * p.h;
      final ix = math.max(0.0, math.min(t.x1, p.x1) - math.max(t.x0, p.x0));
      final iy = math.max(0.0, math.min(t.y1, p.y1) - math.max(t.y0, p.y0));
      final held = t.area <= 0.12 * p.area && ix * iy >= 0.7 * t.area && (t.y0 + t.y1) / 2 >= p.y0 + 0.3 * p.h;
      if (atFeet || held) {
        out.add(i);
        break;
      }
    }
  }
  if (stays.isEmpty) {
    var main = -1;
    var best = 0.0;
    for (var i = 0; i < things.length; i++) {
      final t = things[i];
      final rank = t.area * t.score * (1.2 - ((t.x0 + t.x1) / 2 / width - 0.5).abs());
      if (rank > best) {
        best = rank;
        main = i;
      }
    }
    if (main >= 0 && things[main].h >= 0.25 * height) out.add(main);
  }
  return out;
}

/// Whether [a] comes within [reach] px of [b] (both outlines at 50%).
bool _touches(Outline a, Outline b, double reach) {
  final r = reach.ceil();
  final area = a.box.grow(r, r);
  final l = math.max(area.l, b.box.l), t = math.max(area.t, b.box.t);
  final rr = math.min(area.r, b.box.r), bb = math.min(area.b, b.box.b);
  if (l >= rr || t >= bb) return false;
  final w = area.w, h = area.h;
  final seeds = Uint8List(w * h);
  for (var y = 0; y < a.box.h; y++) {
    for (var x = 0; x < a.box.w; x++) {
      if (a.alpha[y * a.box.w + x] >= 128) seeds[(y + r) * w + x + r] = 1;
    }
  }
  final d = distanceTo(w, h, seeds);
  for (var y = t; y < bb; y++) {
    for (var x = l; x < rr; x++) {
      if (b.alpha[(y - b.box.t) * b.box.w + x - b.box.l] >= 128 && d[(y - area.t) * w + x - area.l] <= reach) {
        return true;
      }
    }
  }
  return false;
}

// ─── Masks ───────────────────────────────────────────────────────────────

/// [masks] with the [things] that go (all but [staying]) added to what's
/// removed: each outline grown by 3% of its height (at least [minGrow] px),
/// as with people. The people staying still win wherever they meet, and the
/// things staying aren't eaten into either.
PeopleMasks withThings(
  PeopleMasks masks,
  List<Thing> things,
  List<Outline> outlines,
  Set<int> staying,
  int width,
  int height, {
  int minGrow = 4,
}) {
  final remove = Uint8List.fromList(masks.remove);
  final kept = Uint8List(width * height);
  for (final i in staying) {
    final o = outlines[i];
    for (var y = 0; y < o.box.h; y++) {
      for (var x = 0; x < o.box.w; x++) {
        if (o.alpha[y * o.box.w + x] >= 128) kept[(o.box.t + y) * width + o.box.l + x] = 1;
      }
    }
  }
  for (var i = 0; i < things.length; i++) {
    if (staying.contains(i)) continue;
    final o = outlines[i];
    final grow = math.max(minGrow, (things[i].h * 0.03).round());
    final box = o.box.grow(grow + 1, grow + 1).clampTo(width, height);
    if (box.w <= 0 || box.h <= 0) continue;
    final seeds = Uint8List(box.w * box.h);
    for (var y = 0; y < o.box.h; y++) {
      for (var x = 0; x < o.box.w; x++) {
        if (o.alpha[y * o.box.w + x] >= 77) seeds[(o.box.t + y - box.t) * box.w + o.box.l + x - box.l] = 1;
      }
    }
    final d = distanceTo(box.w, box.h, seeds);
    for (var y = 0; y < box.h; y++) {
      for (var x = 0; x < box.w; x++) {
        final j = (box.t + y) * width + box.l + x;
        if (d[y * box.w + x] <= grow && masks.keep[j] == 0 && kept[j] == 0) remove[j] = 255;
      }
    }
  }
  return PeopleMasks(remove, masks.keep, masks.removed, masks.kept);
}
