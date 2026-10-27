import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/edit/erase.dart';

/// A [w] x [h] RGBA photo painted by [paint] (x, y) -> (r, g, b).
Uint8List photo(int w, int h, (int, int, int) Function(int x, int y) paint) {
  final o = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b) = paint(x, y);
      final i = (y * w + x) * 4;
      o[i] = r;
      o[i + 1] = g;
      o[i + 2] = b;
      o[i + 3] = 255;
    }
  }
  return o;
}

(int, int, int) grey(int v) => (v, v, v);

/// Mask with the rectangle [l, r) x [t, b) set.
Uint8List rectMask(int w, int h, int l, int t, int r, int b) {
  final m = Uint8List(w * h);
  for (var y = t; y < b; y++) {
    m.fillRange(y * w + l, y * w + r, 255);
  }
  return m;
}

/// [a] with the rectangle [l, r) x [t, b) painted [c].
Uint8List paintRect(Uint8List a, int w, int l, int t, int r, int b, (int, int, int) c) {
  final o = Uint8List.fromList(a);
  for (var y = t; y < b; y++) {
    for (var x = l; x < r; x++) {
      final i = (y * w + x) * 4;
      o[i] = c.$1;
      o[i + 1] = c.$2;
      o[i + 2] = c.$3;
    }
  }
  return o;
}

/// Standard deviation of the red channel over [l, r) x [t, b).
double spread(Uint8List rgba, int w, int l, int t, int r, int b) {
  var s = 0.0, s2 = 0.0, n = 0;
  for (var y = t; y < b; y++) {
    for (var x = l; x < r; x++) {
      final v = rgba[(y * w + x) * 4].toDouble();
      s += v;
      s2 += v * v;
      n++;
    }
  }
  final mean = s / n;
  return math.sqrt(math.max(0, s2 / n - mean * mean));
}

/// Mean absolute difference between [a] and [b] over [l, r) x [t, b).
double error(Uint8List a, Uint8List b, int w, int l, int t, int r, int bottom) {
  var s = 0, n = 0;
  for (var y = t; y < bottom; y++) {
    for (var x = l; x < r; x++) {
      final i = (y * w + x) * 4;
      for (var k = 0; k < 3; k++) {
        s += (a[i + k] - b[i + k]).abs();
      }
      n += 3;
    }
  }
  return s / n;
}

void main() {
  group('Erase', () {
    const w = 240, h = 200;

    test('an empty mask changes nothing', () {
      final img = photo(w, h, (x, y) => grey((x * 7 + y * 3) % 256));
      expect(erase(EraseJob(width: w, height: h, rgba: img, mask: Uint8List(w * h))), img);
    });

    test('removes the object and leaves the rest of the photo alone', () {
      final rnd = math.Random(1);
      final clean = photo(w, h, (x, y) => grey(110 + rnd.nextInt(40)));
      final img = paintRect(clean, w, 100, 80, 140, 120, (230, 20, 20));
      final job = EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 100, 80, 140, 120));
      final out = erase(job);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final inside = x >= 100 - job.growPx && x < 140 + job.growPx && y >= 80 - job.growPx && y < 120 + job.growPx;
          if (!inside) {
            expect(out.sublist(i, i + 4), img.sublist(i, i + 4), reason: 'moved ($x, $y)');
          } else {
            expect(out[i] - out[i + 1], lessThan(40), reason: 'red left at ($x, $y)');
          }
        }
      }
    });

    test('keeps fine grain instead of smearing it', () {
      final rnd = math.Random(7);
      final img = photo(w, h, (x, y) => grey(100 + rnd.nextInt(60)));
      final out = erase(EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 90, 70, 150, 130)));
      final sdFill = spread(out, w, 95, 75, 145, 125), sdPhoto = spread(img, w, 0, 0, 80, 60);
      expect(sdFill, greaterThan(sdPhoto * 0.85), reason: 'fill $sdFill vs photo $sdPhoto');
    });

    test('carries stripes through the hole', () {
      final rnd = math.Random(3);
      final clean = photo(w, h, (x, y) => grey((y ~/ 6).isEven ? 70 + rnd.nextInt(16) : 170 + rnd.nextInt(16)));
      final img = paintRect(clean, w, 95, 75, 145, 125, (20, 200, 40));
      final out = erase(EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 95, 75, 145, 125)));
      final e = error(out, clean, w, 95, 75, 145, 125);
      expect(e, lessThan(15), reason: 'mean error $e');
    });

    test('never copies from the avoid area', () {
      final rnd = math.Random(5);
      var img = photo(w, h, (x, y) => grey(120 + rnd.nextInt(30)));
      img = paintRect(img, w, 60, 60, 90, 140, (40, 220, 40)); // someone to keep, right beside the hole
      final out = erase(
        EraseJob(
          width: w,
          height: h,
          rgba: img,
          mask: rectMask(w, h, 100, 60, 150, 140),
          avoid: rectMask(w, h, 60, 60, 90, 140),
        ),
      );
      for (var y = 60; y < 140; y++) {
        for (var x = 100; x < 150; x++) {
          final i = (y * w + x) * 4;
          expect(out[i + 1] - out[i], lessThan(40), reason: 'green copied to ($x, $y)');
        }
      }
    });

    test('follows a guide for what the photo cannot show', () {
      // A dark rock wholly hidden behind the object (another lies in plain
      // view): nothing around the hole hints at it; a guide (here the true
      // scene at 1/4 detail, as from an inpainting network) does.
      final rnd = math.Random(11);
      bool rock(int x, int y) =>
          (x >= 110 && x < 130 && y >= 90 && y < 110) || (x >= 20 && x < 40 && y >= 20 && y < 40);
      final clean = photo(w, h, (x, y) => grey((rock(x, y) ? 50 : 170) + rnd.nextInt(20)));
      final mask = rectMask(w, h, 90, 70, 150, 130);
      final blurred = Uint8List.fromList(clean);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4, j = ((y & ~3) * w + (x & ~3)) * 4;
          blurred.setRange(i, i + 3, clean, j);
        }
      }
      final plain = error(erase(EraseJob(width: w, height: h, rgba: clean, mask: mask)), clean, w, 90, 70, 150, 130);
      final guided = error(
        erase(EraseJob(width: w, height: h, rgba: clean, mask: mask, guide: blurred)),
        clean,
        w,
        90,
        70,
        150,
        130,
      );
      expect(guided, lessThan(13));
      expect(guided, lessThan(plain * 0.7), reason: 'guided $guided, unguided $plain');
    });

    test('fills cleanly up to the photo edge', () {
      // Things cut off by the frame: the edge rows have no full patches of
      // their own, and junk (here from the colourful rug on the left) must
      // not end up there.
      final rnd = math.Random(13);
      final tiles = [for (var i = 0; i < 64; i++) (rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256))];
      var img = photo(w, h, (x, y) => x < 60 ? tiles[(y ~/ 8 * 8 + x ~/ 8) % 64] : grey(120 + rnd.nextInt(30)));
      img = paintRect(img, w, 150, 120, 240, 200, (230, 20, 20)); // the object, in the corner
      final out = erase(EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 150, 120, 240, 200)));
      for (var y = 120; y < h; y++) {
        for (var x = 150; x < w; x++) {
          final i = (y * w + x) * 4;
          final grey = (out[i] - out[i + 1]).abs() + (out[i + 1] - out[i + 2]).abs();
          expect(grey, lessThan(40), reason: 'colour at ($x, $y)');
        }
      }
    });

    test('same job, same result', () {
      final rnd = math.Random(9);
      final img = photo(w, h, (x, y) => (rnd.nextInt(256), rnd.nextInt(256), 90));
      final job = EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 30, 40, 70, 90));
      expect(erase(job), erase(job));
    });

    test('runs off the UI isolate and reports progress', () async {
      final img = photo(w, h, (x, y) => grey((x ~/ 8 + y ~/ 8).isEven ? 60 : 190));
      final job = EraseJob(width: w, height: h, rgba: img, mask: rectMask(w, h, 100, 80, 140, 120));
      final progress = <double>[];
      final out = await eraseObjects(job, onProgress: progress.add);
      expect(out, erase(job));
      expect(progress.last, 1.0);
    });
  });
}
