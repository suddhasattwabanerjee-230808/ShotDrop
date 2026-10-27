import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/people/people.dart';
import 'package:shotdrop/people/things.dart';

/// A finder output (300 rows) with [things] in it: class, sure as [score],
/// centre and size 0..1 of the region; every other row sure of nothing.
(Float32List, Float32List) finderOut(List<(int kind, double score, double cx, double cy, double w, double h)> things) {
  final logits = Float32List(300 * thingClasses)..fillRange(0, 300 * thingClasses, -9);
  final boxes = Float32List(300 * 4);
  for (final (i, (kind, score, cx, cy, w, h)) in things.indexed) {
    logits[i * thingClasses + kind] = math.log(score / (1 - score));
    boxes.setAll(i * 4, [cx, cy, w, h]);
  }
  return (logits, boxes);
}

Thing thing(double x0, double y0, double x1, double y1, [String kind = 'Car']) => Thing(x0, y0, x1, y1, 0.8, kind);
Found person(double x0, double y0, double x1, double y1) => Found(x0, y0, x1, y1, 0.9);

/// An outline filling [box] fully.
Outline solid(Box box) => Outline(box, Uint8List(box.w * box.h)..fillRange(0, box.w * box.h, 255));
Outline solidOf(Found f) => solid(Box(f.x0.round(), f.y0.round(), f.x1.round(), f.y1.round()));

void main() {
  group('Finding things', () {
    test('reads only the unwanted kinds, in photo pixels', () {
      const bus = 56, chair = 3, hat = 5;
      final (logits, boxes) = finderOut([
        (bus, 0.8, 0.5, 0.5, 0.2, 0.1),
        (chair, 0.9, 0.2, 0.2, 0.1, 0.1), // part of the place
        (hat, 0.9, 0.7, 0.2, 0.05, 0.05), // worn
        (bus, 0.3, 0.8, 0.8, 0.1, 0.1), // not sure enough
      ]);
      final found = finderThings(logits, boxes, const Box(0, 0, 1000, 800), 1000, 800);
      expect(found, hasLength(1));
      expect(found.single.kind, 'Bus');
      expect(found.single.x0, closeTo(400, 1e-3));
      expect(found.single.y1, closeTo(440, 1e-3));
      expect(found.single.score, closeTo(0.8, 1e-6));
    });

    test('a tile leaves what its edge cuts off to the rest', () {
      final (logits, boxes) = finderOut([(45, 0.8, 0.02, 0.5, 0.06, 0.1), (45, 0.8, 0.5, 0.5, 0.1, 0.1)]);
      final found = finderThings(logits, boxes, const Box(300, 0, 900, 500), 1000, 800);
      expect(found, hasLength(1));
      expect(found.single.kind, 'Bin');
      expect(found.single.x0, closeTo(570, 1e-3));
    });

    test('looks at the whole photo and 2 x 2 tiles', () {
      final r = thingRegions(1600, 1200);
      expect(r, hasLength(5));
      for (final b in r) {
        expect(b.l >= 0 && b.t >= 0 && b.r <= 1600 && b.b <= 1200, isTrue, reason: '$b');
      }
    });

    test('the outliner gets the box corners in its 1024 px view', () {
      final (corners, labels) = samPrompt(thing(100, 50, 300, 250), 2048, 1536);
      expect(corners, [50, 25, 150, 125]);
      expect(labels, [2, 3]);
      expect(samMaskSizeFor(2048, 1536), (256, 192));
    });
  });

  group('Outlining things', () {
    test('only inside its box, from the outliner\'s scores', () {
      // A 100 x 100 photo, scores over 50 x 50: on in x 10..30, y 10..20.
      final mask = Float32List(50 * 50)..fillRange(0, 2500, -10);
      for (var y = 0; y < 50; y++) {
        for (var x = 0; x < 50; x++) {
          if (x >= 5 && x < 40 && y >= 5 && y < 10) mask[y * 50 + x] = 10;
        }
      }
      final o = thingOutline(thing(20, 10, 60, 20), mask, 50, 50, 100, 100);
      int at(int x, int y) => o.alpha[(y - o.box.t) * o.box.w + x - o.box.l];
      expect(at(40, 15), 255);
      expect(o.box.r, lessThan(70), reason: 'what runs on past the box is left');
    });

    test('next to nothing outlined: the whole box', () {
      final mask = Float32List(50 * 50)..fillRange(0, 2500, -10);
      final o = thingOutline(thing(20, 10, 60, 20), mask, 50, 50, 100, 100);
      int at(int x, int y) => o.alpha[(y - o.box.t) * o.box.w + x - o.box.l];
      expect(at(40, 15), 255);
      expect(at(21, 11), 255);
    });
  });

  group('Which things stay', () {
    const w = 1600, h = 1200;
    final subject = person(700, 200, 1000, 1150);

    Set<int> staying(List<Thing> things, {bool anyone = true}) => thingsStaying(
      things,
      [for (final t in things) solidOf(t)],
      [subject],
      [solidOf(subject)],
      anyone ? {0} : {},
      w,
      h,
    );

    test('the bus behind the subject goes, the bike at their feet stays', () {
      final bus = thing(300, 300, 720, 700, 'Bus'); // touches them, but far back
      final bike = thing(600, 800, 900, 1160, 'Bicycle'); // touches them, at their feet
      final bin = thing(100, 600, 200, 800, 'Bin'); // nowhere near
      expect(staying([bus, bike, bin]), {1});
    });

    test('their bag stays, someone else\'s goes', () {
      final theirs = thing(950, 600, 1020, 700, 'Bag');
      final dropped = thing(1300, 1000, 1400, 1100, 'Bag');
      expect(staying([theirs, dropped]), {0});
    });

    test('something too big to rebuild stays', () {
      expect(staying([thing(0, 0, 1000, 700, 'Bus')]), {0});
    });

    test('with no one staying, a big thing near the middle is the subject', () {
      final car = thing(500, 300, 1100, 900);
      final cone = thing(100, 900, 160, 1000, 'Cone');
      expect(staying([car, cone], anyone: false), {0});
      expect(staying([cone], anyone: false), isEmpty);
    });
  });

  group('Masks', () {
    test('things that go are grown into what\'s removed, never into who or what stays', () {
      const w = 200, h = 100;
      final people = PeopleMasks(Uint8List(w * h), Uint8List(w * h), 0, 1);
      // Who stays: x 100..140.
      for (var y = 0; y < h; y++) {
        people.keep.fillRange(y * w + 100, y * w + 140, 255);
      }
      final going = thing(60, 20, 100, 80, 'Bin');
      final kept = thing(140, 20, 190, 80, 'Bicycle');
      final m = withThings(people, [going, kept], [solidOf(going), solidOf(kept)], {1}, w, h);
      expect(m.remove[50 * w + 80], 255);
      expect(m.remove[50 * w + 57], 255, reason: 'grown');
      expect(m.remove[50 * w + 100], 0, reason: 'who stays');
      expect(m.remove[50 * w + 160], 0, reason: 'what stays');
      expect(people.remove[50 * w + 80], 0, reason: 'the people\'s masks are left as they were');
    });
  });
}
