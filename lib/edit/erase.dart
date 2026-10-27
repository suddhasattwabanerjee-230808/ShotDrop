import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Magic eraser: removes whatever the mask covers (people, objects, wires,
/// litter) and rebuilds what would have been behind it.
///
/// The fill is made only of real pixels from the same photo, never painted
/// or blurred in, so grain, focus and texture match the rest of the shot.
/// It is a multi-scale PatchMatch completion (Wexler, Shechtman & Irani 2007;
/// Barnes et al. 2009, the method behind Photoshop's Content-Aware Fill):
///
///  1. Each removed object becomes a hole, grown a little past the mask so
///     edge halos and fringes go with it.
///  2. Nearby holes are grouped, and each group gets a context window about
///     its own size on every side to borrow from.
///  3. The window is shrunk down a pyramid until the hole is only a few
///     pixels deep, and filled there from its rim inwards, each pixel copied
///     from the patch that best matches what is already known around it.
///  4. Working back up, every 7x7 patch touching the hole is matched to its
///     most similar fully-known patch (PatchMatch: random guesses, spread to
///     neighbours, refined by a shrinking random search); far-off sources
///     must match clearly better than nearby ones, since content next to the
///     hole has the right lighting, scale and perspective. Each hole pixel is
///     then copied from the best covering patch. A few match/copy rounds per
///     level settle the fill into one coherent texture, and each level's
///     matches seed the next, so large structures (horizons, walls, paths)
///     are laid out coarse and the fine levels add real detail.
///  5. The copy's tone is evened out across chunk edges, a smooth colour
///     correction from the hole's rim removes any brightness shift
///     (vignetting, sky gradients), and the fill is feathered into the photo
///     over the outer band of the hole.
///
/// Patches alone can only continue what shows around the hole. For what it
/// can't show (a log running behind a person, a doorway), a [EraseJob.guide]
/// from an inpainting network sets the layout and the engine still renders
/// it from the photo's own pixels.
///
/// Runs on any RGBA buffer; [eraseObjects] runs it off the UI isolate.

/// One removal job. [rgba] is [width] x [height] straight RGBA; [mask] is one
/// byte per pixel, 0 = keep, >0 = remove (soft selections are fine: anything
/// above [maskThreshold] is removed).
class EraseJob {
  EraseJob({
    required this.width,
    required this.height,
    required this.rgba,
    required this.mask,
    this.avoid,
    this.protect,
    this.guide,
    this.guideScale = 4,
    this.grow,
    this.feather,
    this.seed = 1,
  }) : assert(rgba.length == width * height * 4),
       assert(mask.length == width * height),
       assert(avoid == null || avoid.length == width * height),
       assert(protect == null || protect.length == width * height),
       assert(guide == null || guide.length == width * height * 4);

  final int width, height;
  final Uint8List rgba, mask;

  /// Optional: pixels never copied into the fill (e.g. other people, faces,
  /// text), 0 = usable, >0 = don't copy. They stay in the photo as they are.
  final Uint8List? avoid;

  /// Optional: pixels left exactly as they are (e.g. the people being kept),
  /// even where the hole grows past the mask into them, and never copied.
  final Uint8List? protect;

  /// Optional: a rough picture of what belongs in the hole, [width] x
  /// [height] RGBA (e.g. an inpainting network's output, scaled up), whose
  /// layout is trusted down to [guideScale] photo pixels. The engine follows
  /// its structure (a log continuing behind a person, a horizon, a doorway)
  /// but rebuilds every pixel from the photo itself, so the result is as
  /// sharp and grainy as the rest of the shot. Only its hole area is read.
  final Uint8List? guide;

  /// Photo pixels per guide pixel of real detail (4 for a 512 px network
  /// output on a 2048 px photo).
  final int guideScale;

  /// How far, in pixels, the hole extends past the mask; null picks one from
  /// the photo size (about 0.4% of the long edge, at least 3 px).
  final int? grow;

  /// Width of the blend at the hole's edge, in pixels; null picks one inside
  /// [grow]. One given must fit inside the mask's own margin around the
  /// object, or the object's edge is blended back in.
  final int? feather;

  /// Seeds the random search, so the same job always gives the same result.
  final int seed;

  int get growPx => grow ?? math.max(3, (math.max(width, height) * 0.004).round());
  int get featherPx => feather ?? math.min(growPx, math.max(2, (growPx * 0.7).round()));
}

/// Mask values above this are removed.
const maskThreshold = 24;

/// See [_Level.near].
const _nearMse = 120;

/// Patch radius: patches are (2r+1)^2 pixels.
const _r = 3;

/// [job]'s photo with the masked area removed, as RGBA, computed on a
/// background isolate. [onProgress] gets 0..1.
Future<Uint8List> eraseObjects(EraseJob job, {void Function(double)? onProgress}) async {
  final port = ReceivePort();
  try {
    await Isolate.spawn(
      _eraseEntry,
      (job, port.sendPort),
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    await for (final m in port) {
      if (m is double) {
        onProgress?.call(m);
      } else if (m is Uint8List) {
        return m;
      } else if (m is List) {
        throw StateError('Erase failed: ${m.first}');
      } else if (m == null) {
        throw StateError('Erase isolate ended without a result');
      }
    }
    throw StateError('Erase isolate ended without a result');
  } finally {
    port.close();
  }
}

void _eraseEntry((EraseJob, SendPort) args) {
  final (job, port) = args;
  var last = -1.0;
  final out = erase(
    job,
    onProgress: (p) {
      if (p - last >= 0.01 || p >= 1) {
        last = p;
        port.send(p);
      }
    },
  );
  Isolate.exit(port, out);
}

/// [job]'s photo with the masked area removed, as RGBA (synchronous; prefer
/// [eraseObjects] from UI code).
Uint8List erase(EraseJob job, {void Function(double)? onProgress}) {
  final w = job.width, h = job.height;
  final out = Uint8List.fromList(job.rgba);
  final groups = _groups(job);
  if (groups.isEmpty) return out;
  final total = groups.fold<double>(0, (s, g) => s + g.holeArea);
  var done = 0.0;
  for (final g in groups) {
    final share = g.holeArea / total;
    final base = done;
    _eraseRegion(job, g.region, out, (p) => onProgress?.call(base + p * share));
    done += share;
  }
  onProgress?.call(1);
  assert(out.length == w * h * 4);
  return out;
}

// ─── Grouping ────────────────────────────────────────────────────────────

class _Group {
  _Group(this.hole, this.region, this.holeArea);
  _Box hole, region;
  double holeArea;
}

class _Box {
  _Box(this.l, this.t, this.r, this.b); // r, b exclusive
  int l, t, r, b;
  int get w => r - l;
  int get h => b - t;
  bool overlaps(_Box o) => l < o.r && o.l < r && t < o.b && o.t < b;
  _Box union(_Box o) => _Box(math.min(l, o.l), math.min(t, o.t), math.max(r, o.r), math.max(b, o.b));
}

/// The masked objects, in groups whose context windows don't touch, each
/// with the window to fill it from. Works on 8 px cells, so it's cheap on
/// any photo size.
List<_Group> _groups(EraseJob job) {
  final w = job.width, h = job.height, m = job.mask;
  const c = 8;
  final gw = (w + c - 1) ~/ c, gh = (h + c - 1) ~/ c;
  final cell = Uint8List(gw * gh);
  for (var y = 0; y < h; y++) {
    final row = y * w, grow = (y ~/ c) * gw;
    for (var x = 0; x < w; x++) {
      if (m[row + x] > maskThreshold) cell[grow + x ~/ c] = 1;
    }
  }
  final pad = job.growPx + 2;
  final groups = <_Group>[];
  final stack = <int>[];
  for (var i = 0; i < cell.length; i++) {
    if (cell[i] != 1) continue;
    var l = gw, t = gh, r = 0, b = 0, n = 0;
    cell[i] = 2;
    stack.add(i);
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      final x = j % gw, y = j ~/ gw;
      n++;
      l = math.min(l, x);
      r = math.max(r, x + 1);
      t = math.min(t, y);
      b = math.max(b, y + 1);
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
          final k = ny * gw + nx;
          if (cell[k] == 1) {
            cell[k] = 2;
            stack.add(k);
          }
        }
      }
    }
    final hole = _Box(
      math.max(0, l * c - pad),
      math.max(0, t * c - pad),
      math.min(w, r * c + pad),
      math.min(h, b * c + pad),
    );
    groups.add(_Group(hole, _context(hole, w, h), n * c * c.toDouble()));
  }
  // Merge groups whose windows overlap, so no window holds part of another hole.
  for (var merged = true; merged;) {
    merged = false;
    outer:
    for (var i = 0; i < groups.length; i++) {
      for (var j = i + 1; j < groups.length; j++) {
        if (!groups[i].region.overlaps(groups[j].region)) continue;
        final a = groups[i], o = groups.removeAt(j);
        a.hole = a.hole.union(o.hole);
        a.region = _context(a.hole, w, h).union(a.region).union(o.region);
        a.holeArea += o.holeArea;
        merged = true;
        break outer;
      }
    }
  }
  return groups;
}

/// The window [hole] is filled from: the hole plus about its own size on
/// every side (at least 64 px), inside the photo.
_Box _context(_Box hole, int w, int h) {
  final m = math.max(64, (math.max(hole.w, hole.h) * 0.9).round());
  return _Box(math.max(0, hole.l - m), math.max(0, hole.t - m), math.min(w, hole.r + m), math.min(h, hole.b + m));
}

// ─── One region ──────────────────────────────────────────────────────────

void _eraseRegion(EraseJob job, _Box box, Uint8List out, void Function(double) onProgress) {
  final W = job.width, w = box.w, h = box.h, n = w * h;
  final rgb = Uint8List(n * 3);
  final object = Uint8List(n);
  final avoid = Uint8List(n);
  final keep = Uint8List(n);
  final guide = job.guide == null ? null : Uint8List(n * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x, j = (box.t + y) * W + box.l + x;
      rgb[i * 3] = job.rgba[j * 4];
      rgb[i * 3 + 1] = job.rgba[j * 4 + 1];
      rgb[i * 3 + 2] = job.rgba[j * 4 + 2];
      if (job.mask[j] > maskThreshold) object[i] = 1;
      final a = job.avoid;
      if (a != null && a[j] > maskThreshold) avoid[i] = 1;
      final p = job.protect;
      if (p != null && p[j] > maskThreshold) {
        keep[i] = avoid[i] = 1;
        object[i] = 0;
      }
      if (guide != null) {
        for (var k = 0; k < 3; k++) {
          guide[i * 3 + k] = job.guide![j * 4 + k];
        }
      }
    }
  }
  // The hole: the object grown by [growPx], so its halo goes with it, but
  // never into what's protected.
  final toObject = _chamfer(w, h, object);
  final grow = job.growPx.toDouble();
  final hole = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (toObject[i] <= grow && keep[i] == 0) hole[i] = 1;
  }

  final filled = _complete(
    w,
    h,
    Uint8List.fromList(rgb),
    hole,
    avoid,
    _Rng(job.seed),
    onProgress,
    guide: guide,
    guideScale: job.guideScale,
  );

  // Colour correction: the difference between the photo and the fill along
  // the hole's rim, spread smoothly over the hole (push-pull on 4 px cells).
  final depth = _chamfer(w, h, _not(hole));
  const c = 4;
  final gw = (w + c - 1) ~/ c, gh = (h + c - 1) ~/ c;
  final gv = Float32List(gw * gh * 3), gwt = Float32List(gw * gh);
  for (var i = 0; i < n; i++) {
    if (hole[i] == 0 || depth[i] > 1.5) continue;
    final g = (i ~/ w ~/ c) * gw + (i % w) ~/ c;
    for (var k = 0; k < 3; k++) {
      gv[g * 3 + k] += (rgb[i * 3 + k] - filled[i * 3 + k]).clamp(-40, 40).toDouble();
    }
    gwt[g] += 1;
  }
  for (var g = 0; g < gwt.length; g++) {
    if (gwt[g] == 0) continue;
    for (var k = 0; k < 3; k++) {
      gv[g * 3 + k] /= gwt[g];
    }
    gwt[g] = 1;
  }
  _pushPull(gw, gh, gv, gwt);

  final feather = job.featherPx.toDouble();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (hole[i] == 0) continue;
      final a = feather <= 0 ? 1.0 : math.min(1.0, depth[i] / feather);
      final j = ((box.t + y) * W + box.l + x) * 4;
      final gx = (x + 0.5) / c - 0.5, gy = (y + 0.5) / c - 0.5;
      for (var k = 0; k < 3; k++) {
        final f = filled[i * 3 + k] + _bilinear(gv, gw, gh, gx, gy, k);
        out[j + k] = (rgb[i * 3 + k] + (f - rgb[i * 3 + k]) * a).round().clamp(0, 255);
      }
    }
  }
}

// ─── Completion ──────────────────────────────────────────────────────────

class _Level {
  _Level(this.w, this.h, this.rgb, this.hole, this.avoid);
  final int w, h;
  final Uint8List rgb, hole, avoid;

  late Uint8List srcOk; // 1 where a patch centred here is fully known and usable
  late Int32List sources; // every such centre
  late Int32List targets; // centres of patches touching the hole, in scan order
  late Int32List tIdx; // pixel -> index in targets, or -1
  late Int32List holes; // hole pixels
  late Int32List slot; // pixel -> index in holes, or -1
  late Float64List conf; // per target: how much its vote counts (edges first)
  late Int32List nnf; // per target: matched source centre
  late Int32List dist; // per target: its patch distance
  double maxDepth = 0;
  double nearK = 0; // see [near]

  /// What a match [s] for target [t] costs on top of its patch difference:
  /// little nearby, growing with the square of the distance, so a far-off
  /// source must match clearly better to win. Content next to the hole is
  /// usually the right content (same lighting, scale and perspective).
  int near(int t, int s) {
    final dx = t % w - s % w, dy = t ~/ w - s ~/ w;
    return (nearK * (dx * dx + dy * dy)).toInt();
  }

  void prepare() {
    final n = w * h;
    final bad = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bad[i] = hole[i] | avoid[i];
    }
    final ib = _integral(w, h, bad), ih = _integral(w, h, hole);
    srcOk = Uint8List(n);
    tIdx = Int32List(n)..fillRange(0, n, -1);
    final src = <int>[], tg = <int>[];
    for (var y = _r; y < h - _r; y++) {
      for (var x = _r; x < w - _r; x++) {
        final i = y * w + x;
        if (_window(ib, w, x, y) == 0) {
          srcOk[i] = 1;
          src.add(i);
        }
        if (_window(ih, w, x, y) > 0) {
          tIdx[i] = tg.length;
          tg.add(i);
        }
      }
    }
    sources = Int32List.fromList(src);
    targets = Int32List.fromList(tg);
    slot = Int32List(n)..fillRange(0, n, -1);
    final hs = <int>[];
    for (var i = 0; i < n; i++) {
      if (hole[i] == 1) {
        slot[i] = hs.length;
        hs.add(i);
      }
    }
    holes = Int32List.fromList(hs);
    final depth = _chamfer(w, h, _not(hole));
    conf = Float64List(targets.length);
    for (var k = 0; k < targets.length; k++) {
      conf[k] = math.pow(1.3, -math.min(depth[targets[k]], 100.0)).toDouble();
    }
    maxDepth = 0;
    for (final i in holes) {
      maxDepth = math.max(maxDepth, depth[i]);
    }
    nnf = Int32List(targets.length);
    dist = Int32List(targets.length);
    // A source three hole-depths away costs as much as every channel of
    // every pixel being [_nearMse] levels apart, squared.
    final reach = math.max(8.0, 3 * maxDepth);
    nearK = _nearMse * (2 * _r + 1) * (2 * _r + 1) * 3 / (reach * reach);
  }

  /// Half the size; a pixel is a hole if any of its four is.
  _Level down() {
    final w2 = (w + 1) >> 1, h2 = (h + 1) >> 1;
    final rgb2 = Uint8List(w2 * h2 * 3), hole2 = Uint8List(w2 * h2), avoid2 = Uint8List(w2 * h2);
    for (var y = 0; y < h2; y++) {
      for (var x = 0; x < w2; x++) {
        var r = 0, g = 0, b = 0, cnt = 0, anyHole = 0, anyAvoid = 0;
        for (var dy = 0; dy < 2; dy++) {
          final yy = y * 2 + dy;
          if (yy >= h) continue;
          for (var dx = 0; dx < 2; dx++) {
            final xx = x * 2 + dx;
            if (xx >= w) continue;
            final i = yy * w + xx;
            anyAvoid |= avoid[i];
            if (hole[i] == 1) {
              anyHole = 1;
              continue;
            }
            r += rgb[i * 3];
            g += rgb[i * 3 + 1];
            b += rgb[i * 3 + 2];
            cnt++;
          }
        }
        final o = y * w2 + x;
        hole2[o] = anyHole;
        avoid2[o] = anyAvoid;
        if (cnt > 0) {
          rgb2[o * 3] = (r / cnt).round();
          rgb2[o * 3 + 1] = (g / cnt).round();
          rgb2[o * 3 + 2] = (b / cnt).round();
        }
      }
    }
    return _Level(w2, h2, rgb2, hole2, avoid2);
  }
}

/// [rgb] with every [hole] pixel rebuilt from the rest (minus [avoid]).
Uint8List _complete(
  int w,
  int h,
  Uint8List rgb,
  Uint8List hole,
  Uint8List avoid,
  _Rng rng,
  void Function(double) onProgress, {
  Uint8List? guide,
  int guideScale = 4,
}) {
  final levels = [_Level(w, h, rgb, hole, avoid)..prepare()];
  while (true) {
    final cur = levels.last;
    if (math.min(cur.w, cur.h) < 4 * (2 * _r + 1)) break;
    // With a guide, start where its detail runs out; without, where the hole
    // is only a few pixels deep.
    if (guide != null ? 1 << (levels.length - 1) >= guideScale : cur.maxDepth <= _r + 1) break;
    final next = cur.down()..prepare();
    if (next.sources.isEmpty) break;
    levels.add(next);
  }

  final top = levels.length - 1;
  // The guide at each level's size.
  final guides = <Uint8List>[?guide];
  for (var k = 1; guide != null && k <= top; k++) {
    guides.add(_halve(guides[k - 1], levels[k - 1].w, levels[k - 1].h));
  }
  // Pulls level [k]'s fill to the guide's layout, as finely as the guide
  // holds detail there, keeping the copied texture.
  void steer(int k) {
    if (guide != null) _blendTone(levels[k], Uint8List.fromList(levels[k].rgb), guides[k], guideScale >> k);
  }

  // With a guide the layout is already set, so the top level needs fewer rounds.
  int emFor(int k) => k == top ? (guide != null ? 3 : 6) : math.min(4, 2 + (k + 1) ~/ 2);
  var work = 0.0, done = 0.0;
  for (var k = 0; k <= top; k++) {
    work += levels[k].targets.length * emFor(k);
  }

  final first = levels[top];
  if (guide != null) {
    for (final i in first.holes) {
      first.rgb.setRange(i * 3, i * 3 + 3, guides[top], i * 3);
    }
  } else if (first.sources.isEmpty) {
    _onionFill(first);
  } else {
    _rimFill(first, rng);
  }
  for (var k = top; k >= 0; k--) {
    final l = levels[k];
    if (k < top) {
      _upsample(levels[k + 1], l, rng);
      steer(k);
    }
    if (l.sources.isEmpty || l.targets.isEmpty) continue;
    if (k == top) {
      for (var t = 0; t < l.targets.length; t++) {
        l.nnf[t] = l.sources[rng.next(l.sources.length)];
      }
    }
    final em = emFor(k);
    for (var e = 0; e < em; e++) {
      _distances(l);
      _patchMatch(l, k == top && e == 0 ? 5 : 2, rng);
      _vote(l);
      steer(k);
      done += l.targets.length;
      onProgress(work == 0 ? 1 : done / work);
    }
  }
  final l0 = levels[0];
  if (guide == null && l0.targets.isNotEmpty && l0.sources.isNotEmpty) _evenTone(l0);
  return l0.rgb;
}

/// [rgb] (3 bytes a pixel, [w] x [h]) at half size, each pixel the mean of
/// the up to four it covers.
Uint8List _halve(Uint8List rgb, int w, int h) {
  final w2 = (w + 1) >> 1, h2 = (h + 1) >> 1;
  final o = Uint8List(w2 * h2 * 3);
  for (var y = 0; y < h2; y++) {
    for (var x = 0; x < w2; x++) {
      for (var k = 0; k < 3; k++) {
        var sum = 0, n = 0;
        for (var yy = y * 2; yy < math.min(h, y * 2 + 2); yy++) {
          for (var xx = x * 2; xx < math.min(w, x * 2 + 2); xx++) {
            sum += rgb[(yy * w + xx) * 3 + k];
            n++;
          }
        }
        o[(y * w2 + x) * 3 + k] = sum ~/ n;
      }
    }
  }
  return o;
}

/// The starting guess at the coarsest level: the hole filled from its rim
/// inwards, each pixel copied from the source patch that best matches the
/// pixels already known around it. Starting from a blur instead (each pixel
/// the mean of its neighbours) lets smooth areas elsewhere in the photo win
/// every match, so a hole in sand would fill with smooth stone.
void _rimFill(_Level l, _Rng rng) {
  final w = l.w, h = l.h, img = l.rgb;
  final known = _not(l.hole);
  final depth = _chamfer(w, h, known);
  final order = l.holes.toList()..sort((a, b) => depth[a].compareTo(depth[b]));
  var cands = l.sources;
  if (cands.length > 3000) {
    cands = Int32List.fromList([for (var i = 0; i < 3000; i++) cands[rng.next(cands.length)]]);
  }
  for (final i in order) {
    final x = i % w, y = i ~/ w;
    final c = y.clamp(_r, h - 1 - _r) * w + x.clamp(_r, w - 1 - _r);
    var best = cands[0], bestD = double.infinity;
    for (final s in cands) {
      var d = 0, n = 0;
      for (var dy = -_r; dy <= _r; dy++) {
        for (var dx = -_r; dx <= _r; dx++) {
          final o = dy * w + dx;
          if (known[c + o] == 0) continue;
          final a = (c + o) * 3, b = (s + o) * 3;
          final e0 = img[a] - img[b], e1 = img[a + 1] - img[b + 1], e2 = img[a + 2] - img[b + 2];
          d += e0 * e0 + e1 * e1 + e2 * e2;
          n++;
        }
      }
      if (n > 0 && d / n < bestD) {
        bestD = d / n;
        best = s;
      }
    }
    final p = (best + i - c) * 3;
    img[i * 3] = img[p];
    img[i * 3 + 1] = img[p + 1];
    img[i * 3 + 2] = img[p + 2];
    known[i] = 1;
  }
}

/// Fills the hole from its edge inwards, each pixel the mean of its already
/// known neighbours (only when there's nothing to copy from).
void _onionFill(_Level l) {
  final w = l.w, h = l.h, rgb = l.rgb;
  final known = _not(l.hole);
  var left = l.holes.toList();
  while (left.isNotEmpty) {
    final next = <int>[], set = <int>[];
    for (final i in left) {
      final x = i % w, y = i ~/ w;
      var r = 0, g = 0, b = 0, cnt = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final j = ny * w + nx;
          if (known[j] == 0) continue;
          r += rgb[j * 3];
          g += rgb[j * 3 + 1];
          b += rgb[j * 3 + 2];
          cnt++;
        }
      }
      if (cnt == 0) {
        next.add(i);
        continue;
      }
      rgb[i * 3] = r ~/ cnt;
      rgb[i * 3 + 1] = g ~/ cnt;
      rgb[i * 3 + 2] = b ~/ cnt;
      set.add(i);
    }
    if (set.isEmpty) break; // nothing known at all
    for (final i in set) {
      known[i] = 1;
    }
    left = next;
  }
}

/// Seeds [fine] from [coarse]: each patch's match is its coarse match scaled
/// up (or a random source when that isn't usable here), and the hole is
/// rebuilt from them.
void _upsample(_Level coarse, _Level fine, _Rng rng) {
  final w = fine.w, cw = coarse.w, ch = coarse.h;
  for (final i in fine.holes) {
    final x = i % w, y = i ~/ w;
    final int j = math.min(y >> 1, ch - 1) * cw + math.min(x >> 1, cw - 1);
    fine.rgb[i * 3] = coarse.rgb[j * 3];
    fine.rgb[i * 3 + 1] = coarse.rgb[j * 3 + 1];
    fine.rgb[i * 3 + 2] = coarse.rgb[j * 3 + 2];
  }
  if (fine.sources.isEmpty) return;
  for (var k = 0; k < fine.targets.length; k++) {
    final t = fine.targets[k], x = t % w, y = t ~/ w;
    // The coarse patch over this one; near the border, where the coarse level
    // has no patch centres, the nearest one, offset to match. (A random
    // source instead fills the edge with junk that then matches itself best,
    // so it never gets fixed.)
    final cx = (x >> 1).clamp(_r, cw - 1 - _r), cy = (y >> 1).clamp(_r, ch - 1 - _r);
    final ct = coarse.tIdx[cy * cw + cx];
    var s = -1;
    if (ct >= 0) {
      final cs = coarse.nnf[ct];
      s = _usableNear(fine, (cs % cw) * 2 + x - cx * 2, (cs ~/ cw) * 2 + y - cy * 2);
    }
    fine.nnf[k] = s >= 0 ? s : fine.sources[rng.next(fine.sources.length)];
  }
  // Rebuild the hole from those matches at this level's own resolution, so
  // the search starts from real texture, not the blurrier coarse fill.
  fine.dist.fillRange(0, fine.dist.length, 0);
  _vote(fine);
}

/// The usable source centre nearest ([x], [y]) in [l], looking up to 2
/// patch widths away; -1 if none.
int _usableNear(_Level l, int x, int y) {
  for (var rad = 0; rad <= 4 * _r; rad++) {
    for (var dy = -rad; dy <= rad; dy++) {
      for (var dx = -rad; dx <= rad; dx++) {
        if (math.max(dx.abs(), dy.abs()) != rad) continue; // this ring only
        final sx = x + dx, sy = y + dy;
        if (sx < _r || sy < _r || sx >= l.w - _r || sy >= l.h - _r) continue;
        if (l.srcOk[sy * l.w + sx] == 1) return sy * l.w + sx;
      }
    }
  }
  return -1;
}

void _distances(_Level l) {
  for (var k = 0; k < l.targets.length; k++) {
    final t = l.targets[k], s = l.nnf[k];
    l.dist[k] = _patchDist(l.rgb, l.w, t, s, 0x7fffffff) + l.near(t, s);
  }
}

/// Sum of squared differences between the patches centred on [t] and [s],
/// giving up once it passes [cutoff].
int _patchDist(Uint8List img, int w, int t, int s, int cutoff) {
  var d = 0;
  for (var dy = -_r; dy <= _r; dy++) {
    var a = (t + dy * w - _r) * 3, b = (s + dy * w - _r) * 3;
    final end = a + (2 * _r + 1) * 3;
    while (a < end) {
      final e = img[a++] - img[b++];
      d += e * e;
    }
    if (d >= cutoff) return d;
  }
  return d;
}

/// PatchMatch: improves each target's match by trying its neighbours'
/// matches shifted by one, then random spots ever closer to its best.
void _patchMatch(_Level l, int iterations, _Rng rng) {
  final w = l.w, h = l.h, img = l.rgb, ok = l.srcOk, tIdx = l.tIdx;
  final targets = l.targets, nnf = l.nnf, dist = l.dist;
  final maxRad = math.max(w, h);
  for (var it = 0; it < iterations; it++) {
    final fwd = it.isEven;
    final step = fwd ? 1 : -1;
    for (var q = 0; q < targets.length; q++) {
      final k = fwd ? q : targets.length - 1 - q;
      final t = targets[k];
      var best = nnf[k], bd = dist[k];
      for (final off in [step, step * w]) {
        final nk = tIdx[t - off];
        if (nk < 0) continue;
        final c = nnf[nk] + off;
        if (c == best || c < 0 || c >= ok.length || ok[c] == 0) continue;
        final p = l.near(t, c);
        if (p >= bd) continue;
        final d = _patchDist(img, w, t, c, bd - p) + p;
        if (d < bd) {
          bd = d;
          best = c;
        }
      }
      final bx = best % w, by = best ~/ w;
      for (var rad = maxRad; rad >= 1; rad >>= 1) {
        final cx = (bx + rng.next(2 * rad + 1) - rad).clamp(_r, w - 1 - _r);
        final cy = (by + rng.next(2 * rad + 1) - rad).clamp(_r, h - 1 - _r);
        final c = cy * w + cx;
        if (c == best || ok[c] == 0) continue;
        final p = l.near(t, c);
        if (p >= bd) continue;
        final d = _patchDist(img, w, t, c, bd - p) + p;
        if (d < bd) {
          bd = d;
          best = c;
        }
      }
      nnf[k] = best;
      dist[k] = bd;
    }
  }
}

/// Each hole pixel is copied from the one covering patch whose match counts
/// most (near the hole's edge and similar); with [mean], it is the weighted
/// mean of what all its covering patches put there. The mean is the classic
/// vote, but it averages fine grain (sand, foliage, sensor noise) into a
/// smear, and the search then prefers smooth sources to match the smear, so
/// the fill drifts to flat stone or sky; copying keeps real pixels throughout.
void _vote(_Level l, {bool mean = false}) {
  final w = l.w, img = l.rgb, targets = l.targets, nnf = l.nnf, slot = l.slot;
  if (targets.isEmpty) return;
  const area = (2 * _r + 1) * (2 * _r + 1) * 3;
  // Similarity scale: the 75th percentile of the patch errors.
  final step = math.max(1, targets.length ~/ 4000);
  final sample = <double>[for (var k = 0; k < targets.length; k += step) l.dist[k] / area]..sort();
  final sigma2 = 2 * (sample[(sample.length * 3) ~/ 4] + 1);
  // Float64: deep in a big hole the weights get tiny, and in Float32 they
  // underflow to 0, leaving those pixels at their blurry starting guess.
  final acc = Float64List(mean ? l.holes.length * 3 : 0), ws = Float64List(l.holes.length);
  final pick = Int32List(mean ? 0 : l.holes.length);
  for (var k = 0; k < targets.length; k++) {
    final t = targets[k], s = nnf[k];
    final wt = l.conf[k] * math.exp(-math.min(60.0, l.dist[k] / area / sigma2));
    if (!mean) {
      for (var dy = -_r; dy <= _r; dy++) {
        final rowT = t + dy * w, rowS = s + dy * w;
        for (var dx = -_r; dx <= _r; dx++) {
          final h = slot[rowT + dx];
          if (h < 0 || wt <= ws[h]) continue;
          ws[h] = wt;
          pick[h] = rowS + dx;
        }
      }
      continue;
    }
    for (var dy = -_r; dy <= _r; dy++) {
      final rowT = t + dy * w, rowS = s + dy * w;
      for (var dx = -_r; dx <= _r; dx++) {
        final h = slot[rowT + dx];
        if (h < 0) continue;
        final p = (rowS + dx) * 3;
        acc[h * 3] += wt * img[p];
        acc[h * 3 + 1] += wt * img[p + 1];
        acc[h * 3 + 2] += wt * img[p + 2];
        ws[h] += wt;
      }
    }
  }
  for (var h = 0; h < l.holes.length; h++) {
    if (ws[h] <= 0) continue;
    final i = l.holes[h] * 3;
    if (!mean) {
      final p = pick[h] * 3;
      img[i] = img[p];
      img[i + 1] = img[p + 1];
      img[i + 2] = img[p + 2];
      continue;
    }
    img[i] = (acc[h * 3] / ws[h]).round().clamp(0, 255);
    img[i + 1] = (acc[h * 3 + 1] / ws[h]).round().clamp(0, 255);
    img[i + 2] = (acc[h * 3 + 2] / ws[h]).round().clamp(0, 255);
  }
}

/// Evens out the tone of the copied fill: copied chunks can come from
/// slightly brighter or darker spots, which shows as patchwork. Keeps the
/// copy's fine detail but takes its smooth tone from the mean vote over the
/// same matches, which blends across chunk edges.
void _evenTone(_Level l) {
  final copy = Uint8List.fromList(l.rgb);
  _vote(l, mean: true);
  _blendTone(l, copy, Uint8List.fromList(l.rgb), 4);
}

/// Sets [l]'s hole pixels to [detail]'s fine detail on [tone]'s smooth
/// tone: detail + blur(tone) - blur(detail), blurring over a box [b] pixels
/// each way.
void _blendTone(_Level l, Uint8List detail, Uint8List tone, int b) {
  if (b < 1) return;
  final w = l.w, h = l.h, w1 = w + 1, out = l.rgb;
  for (var k = 0; k < 3; k++) {
    final sd = _integral3(w, h, detail, k), st = _integral3(w, h, tone, k);
    for (final i in l.holes) {
      final x = i % w, y = i ~/ w;
      final x0 = math.max(0, x - b), x1 = math.min(w, x + b + 1);
      final y0 = math.max(0, y - b), y1 = math.min(h, y + b + 1);
      final d = sd[y1 * w1 + x1] - sd[y0 * w1 + x1] - sd[y1 * w1 + x0] + sd[y0 * w1 + x0];
      final t = st[y1 * w1 + x1] - st[y0 * w1 + x1] - st[y1 * w1 + x0] + st[y0 * w1 + x0];
      out[i * 3 + k] = (detail[i * 3 + k] + (t - d) / ((x1 - x0) * (y1 - y0))).round().clamp(0, 255);
    }
  }
}

/// Summed-area table of channel [k] of [rgb], (w+1) x (h+1).
Int32List _integral3(int w, int h, Uint8List rgb, int k) {
  final s = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var row = 0;
    for (var x = 0; x < w; x++) {
      row += rgb[(y * w + x) * 3 + k];
      s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row;
    }
  }
  return s;
}

// ─── Helpers ─────────────────────────────────────────────────────────────

Uint8List _not(Uint8List m) {
  final o = Uint8List(m.length);
  for (var i = 0; i < m.length; i++) {
    o[i] = m[i] == 0 ? 1 : 0;
  }
  return o;
}

/// Distance (chamfer, close to Euclidean) from each pixel of a [w] x [h]
/// grid to the nearest one where [seeds] is non-zero.
Float32List distanceTo(int w, int h, Uint8List seeds) => _chamfer(w, h, seeds);

/// Distance (chamfer, close to Euclidean) from each pixel to the nearest
/// pixel where [seeds] is non-zero.
Float32List _chamfer(int w, int h, Uint8List seeds) {
  const far = 1e9, d1 = 1.0, d2 = 1.4142135;
  final d = Float32List(w * h);
  for (var i = 0; i < d.length; i++) {
    d[i] = seeds[i] != 0 ? 0 : far;
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      var v = d[i];
      if (x > 0) v = math.min(v, d[i - 1] + d1);
      if (y > 0) {
        v = math.min(v, d[i - w] + d1);
        if (x > 0) v = math.min(v, d[i - w - 1] + d2);
        if (x < w - 1) v = math.min(v, d[i - w + 1] + d2);
      }
      d[i] = v;
    }
  }
  for (var y = h - 1; y >= 0; y--) {
    for (var x = w - 1; x >= 0; x--) {
      final i = y * w + x;
      var v = d[i];
      if (x < w - 1) v = math.min(v, d[i + 1] + d1);
      if (y < h - 1) {
        v = math.min(v, d[i + w] + d1);
        if (x < w - 1) v = math.min(v, d[i + w + 1] + d2);
        if (x > 0) v = math.min(v, d[i + w - 1] + d2);
      }
      d[i] = v;
    }
  }
  return d;
}

/// Summed-area table of [m], (w+1) x (h+1).
Int32List _integral(int w, int h, Uint8List m) {
  final s = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var row = 0;
    for (var x = 0; x < w; x++) {
      row += m[y * w + x];
      s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row;
    }
  }
  return s;
}

/// Sum of the patch centred on ([x], [y]) from [_integral].
int _window(Int32List s, int w, int x, int y) {
  final w1 = w + 1, x0 = x - _r, y0 = y - _r, x1 = x + _r + 1, y1 = y + _r + 1;
  return s[y1 * w1 + x1] - s[y0 * w1 + x1] - s[y1 * w1 + x0] + s[y0 * w1 + x0];
}

/// Fills the cells with weight < 1 by smooth interpolation of the weighted
/// ones (push-pull: average down a pyramid, blend back up).
void _pushPull(int w, int h, Float32List v, Float32List wt) {
  if (w <= 1 && h <= 1) return;
  final w2 = (w + 1) >> 1, h2 = (h + 1) >> 1;
  final v2 = Float32List(w2 * h2 * 3), wt2 = Float32List(w2 * h2);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x, o = (y >> 1) * w2 + (x >> 1);
      final a = wt[i];
      if (a == 0) continue;
      for (var k = 0; k < 3; k++) {
        v2[o * 3 + k] += a * v[i * 3 + k];
      }
      wt2[o] += a;
    }
  }
  for (var o = 0; o < wt2.length; o++) {
    if (wt2[o] == 0) continue;
    for (var k = 0; k < 3; k++) {
      v2[o * 3 + k] /= wt2[o];
    }
    wt2[o] = math.min(1, wt2[o]);
  }
  _pushPull(w2, h2, v2, wt2);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x, a = wt[i];
      if (a >= 1) continue;
      final gx = (x + 0.5) / 2 - 0.5, gy = (y + 0.5) / 2 - 0.5;
      for (var k = 0; k < 3; k++) {
        v[i * 3 + k] = a * v[i * 3 + k] + (1 - a) * _bilinear(v2, w2, h2, gx, gy, k);
      }
    }
  }
}

double _bilinear(Float32List v, int w, int h, double x, double y, int k) {
  x = x.clamp(0, w - 1.0);
  y = y.clamp(0, h - 1.0);
  final x0 = x.floor(), y0 = y.floor();
  final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
  final fx = x - x0, fy = y - y0;
  final a = v[(y0 * w + x0) * 3 + k], b = v[(y0 * w + x1) * 3 + k];
  final c = v[(y1 * w + x0) * 3 + k], d = v[(y1 * w + x1) * 3 + k];
  return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
}

/// xorshift32: fast, seeded, plenty random for a search.
class _Rng {
  _Rng(int seed) : _s = seed == 0 ? 0x9e3779b9 : seed & 0xffffffff;
  int _s;
  int next(int n) {
    var s = _s;
    s ^= (s << 13) & 0xffffffff;
    s ^= s >> 17;
    s ^= (s << 5) & 0xffffffff;
    _s = s;
    return s % n;
  }
}
