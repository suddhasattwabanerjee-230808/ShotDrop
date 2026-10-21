import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/edit/body.dart';
import 'package:shotdrop/edit/crop.dart';
import 'package:shotdrop/edit/filters.dart';
import 'package:shotdrop/edit/render.dart';
import 'package:shotdrop/edit/reshape.dart';
import 'package:shotdrop/edit/story.dart';
import 'package:shotdrop/models.dart';
import 'package:shotdrop/publish.dart';
import 'package:shotdrop/stores.dart';

CardFile f(String path, {int modified = 1000, int size = 10}) => CardFile(
  uri: 'content://x/$path',
  docId: '1A2B-3C4D:$path',
  name: path.split('/').last,
  size: size,
  modified: modified,
);

void main() {
  group('pairShots', () {
    test('pairs JPG and NEF of the same shot, newest first, drops other files', () {
      final shots = pairShots([
        f('DCIM/100D5600/DSC_0001.JPG', modified: 100),
        f('DCIM/100D5600/DSC_0001.NEF', modified: 100),
        f('DCIM/100D5600/DSC_0002.JPG', modified: 200),
        f('DCIM/100D5600/DSC_0003.NEF', modified: 300),
        f('DCIM/100D5600/NC_FLLST.DAT', modified: 400),
      ]);
      expect(shots.map((s) => s.name), ['DSC_0003', 'DSC_0002', 'DSC_0001']);
      expect(shots[0].editable, isFalse); // RAW only
      expect(shots[0].hasRaw, isTrue);
      expect(shots[1].hasRaw, isFalse);
      expect(shots[2].jpg!.extension, 'JPG');
      expect(shots[2].nef!.extension, 'NEF');
    });

    test('same file name in two folders stays two shots', () {
      final shots = pairShots([f('DCIM/100D5600/DSC_0001.JPG'), f('DCIM/101D5600/DSC_0001.JPG')]);
      expect(shots, hasLength(2));
      expect(shots[0].id, isNot(shots[1].id));
    });
  });

  test('EditParams survive a JSON round trip', () {
    const p = EditParams(
      quarterTurns: 3,
      flipH: true,
      straighten: -2.5,
      crop: Rect.fromLTWH(0.1, 0.2, 0.5, 0.6),
      aspect: AspectPreset.portrait,
      height: 0.2,
      heightBand: (0.4, 0.95),
      slim: 0.6,
      hips: 0.2,
      legs: 0.9,
      body: BodyAnchors(
        waist: BodyArea(0.5, 0.4, 0.2, 0.1),
        hips: BodyArea(0.5, 0.55, 0.22, 0.08),
        legs: [BodyArea(0.42, 0.8, 0.06, 0.15), BodyArea(0.58, 0.8, 0.06, 0.15)],
        legBand: (0.55, 0.97),
        found: true,
      ),
      filter: 'film',
      warmth: 0.3,
    );
    final back = EditParams.fromJson(p.toJson());
    expect(back.toJson(), p.toJson());
  });

  group('filters', () {
    test('identity chain stays identity, and the Original preset with no sliders is a no-op', () {
      expect(isIdentity(chain([identityMatrix, identityMatrix])), isTrue);
      expect(isIdentity(matrixFor(const EditParams())), isTrue);
    });

    test('multiply applies the right-hand matrix first', () {
      // Brighten by 60 then double: 2 * (x + 60) = 2x + 120 on each channel.
      final m = multiply(contrastMatrix(1 / 0.6), brightnessMatrix(1)); // contrast scale 2, offset -128
      expect(m[0], closeTo(2, 1e-9));
      expect(m[4], closeTo(2 * 60 - 128, 1e-9));
    });

    test('mono has equal rows (greyscale)', () {
      final m = presetById('mono').build();
      expect(m.sublist(0, 3), m.sublist(5, 8));
      expect(m.sublist(0, 3), m.sublist(10, 13));
    });

    test('every preset id is unique and resolvable', () {
      final ids = filterPresets.map((p) => p.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      for (final id in ids) {
        expect(presetById(id).id, id);
      }
      expect(presetById('nope').id, 'original');
    });
  });

  group('BandWarp', () {
    test('keeps the ends fixed and is monotonic', () {
      for (final amount in [-0.4, -0.1, 0.15, 0.4]) {
        final w = BandWarp(0.4, 0.9, amount);
        expect(w.map(0), closeTo(0, 1e-9));
        expect(w.map(1), closeTo(1, 1e-9));
        var last = -1.0;
        for (var i = 0; i <= 200; i++) {
          final y = w.map(i / 200);
          expect(y, greaterThan(last));
          last = y;
        }
      }
    });

    test('a positive amount makes the band longer, a negative one shorter', () {
      final taller = BandWarp(0.4, 0.9, 0.3);
      final shorter = BandWarp(0.4, 0.9, -0.3);
      double len(BandWarp w) => w.map(0.9) - w.map(0.4);
      expect(len(taller), greaterThan(0.5));
      expect(len(shorter), lessThan(0.5));
    });

    test('unmap inverts map', () {
      final w = BandWarp(0.2, 0.7, 0.35);
      for (final t in [0.0, 0.1, 0.33, 0.5, 0.8, 1.0]) {
        expect(w.unmap(w.map(t)), closeTo(t, 1e-4));
      }
    });

    test('zero amount is the identity', () {
      final w = BandWarp(0.2, 0.7, 0);
      expect(w.isIdentity, isTrue);
      expect(w.map(0.37), 0.37);
      expect(w.growth, 1);
    });

    test('stretch grows the photo by the band\'s extra length and leaves the rest its size', () {
      final w = BandWarp(0.4, 0.9, 0.3);
      expect(w.growth, closeTo(1 + 0.3 * 0.5, 0.01));
      // Above the band, a stretch of photo is just as tall in the grown photo.
      expect((w.map(0.2) - w.map(0.1)) * w.growth, closeTo(0.1, 1e-3));
    });
  });

  group('body tools', () {
    // A person standing in the middle: shoulders at y 0.25, hips at 0.5, ankles at 0.9.
    final standing = <int, (double, double, double)>{
      11: (0.42, 0.25, 0.99),
      12: (0.58, 0.25, 0.99),
      23: (0.45, 0.5, 0.99),
      24: (0.55, 0.5, 0.99),
      25: (0.45, 0.7, 0.9),
      26: (0.55, 0.7, 0.9),
      27: (0.45, 0.9, 0.9),
      28: (0.55, 0.9, 0.9),
    };

    test('pose landmarks place the waist, hips, legs and the stretch band', () {
      final b = BodyAnchors.fromLandmarks(standing)!;
      expect(b.found, isTrue);
      expect(b.waist.cx, closeTo(0.5, 1e-9));
      expect(b.waist.cy, inExclusiveRange(0.25, 0.5)); // between shoulders and hips
      expect(b.hips.cy, greaterThanOrEqualTo(0.5));
      expect(b.legs.map((l) => l.cx), [closeTo(0.45, 1e-9), closeTo(0.55, 1e-9)]);
      expect(b.legBand!.$1, closeTo(0.5, 1e-9));
      expect(b.legBand!.$2, closeTo(0.9, 1e-9));
    });

    test('no clear shoulders or hips means no body', () {
      expect(BodyAnchors.fromLandmarks({...standing, 11: (0.42, 0.25, 0.2)}), isNull);
      expect(BodyAnchors.fromLandmarks(const {}), isNull);
    });

    test('hidden legs are guessed down from the hips', () {
      final b = BodyAnchors.fromLandmarks({for (final e in standing.entries) if (e.key < 25) e.key: e.value})!;
      expect(b.legs, hasLength(2));
      expect(b.legs.first.cy, greaterThan(0.5));
    });

    test('anchors survive JSON', () {
      final b = BodyAnchors.fromLandmarks(standing)!;
      final back = BodyAnchors.fromJson(b.toJson())!;
      expect(back.toJson(), b.toJson());
    });

    test('slim pulls the waist edges in, leaves far-away pixels alone, and never folds over', () {
      const area = BodyArea(0.5, 0.4, 0.2, 0.12);
      final slim = LocalWarp(area, maxSlim);
      expect(slim.dx(0.4, 0.4), greaterThan(0)); // left edge moves right (inwards)
      expect(slim.dx(0.6, 0.4), lessThan(0)); // right edge moves left
      expect(slim.dx(0.5, 0.4), 0); // the centre line stays
      expect(slim.dx(0.5, 0.95).abs(), lessThan(1e-6)); // far below: untouched
      for (final w in [slim, LocalWarp(area, maxHips)]) {
        var last = -1.0;
        for (var i = 0; i <= 400; i++) {
          final x = i / 400;
          final moved = x + w.dx(x, 0.4);
          expect(moved, greaterThan(last));
          last = moved;
        }
      }
    });

    test('legs slide in towards each other at the knees, not at the hips or ankles', () {
      const body = BodyAnchors.defaults;
      final warps = bodyWarps(0, 0, 1, body);
      final (left, right) = (warps[0], warps[1]);
      expect(left.dx(body.legs[0].cx, body.legs[0].cy), greaterThan(0.02));
      expect(right.dx(body.legs[1].cx, body.legs[1].cy), lessThan(-0.02));
      final top = body.legs[0].cy - body.legs[0].ry * 0.9;
      expect(left.dx(body.legs[0].cx, top), lessThan(left.dx(body.legs[0].cx, body.legs[0].cy) * 0.1));
      // Across the knees, nothing folds over.
      var last = -1.0;
      for (var i = 0; i <= 400; i++) {
        final x = i / 400;
        final moved = x + left.dx(x, body.legs[0].cy) + right.dx(x, body.legs[0].cy);
        expect(moved, greaterThan(last));
        last = moved;
      }
    });

    test('hip lifts the hips up without folding', () {
      const body = BodyAnchors.defaults;
      final hip = bodyWarps(0, 1, 0, body).single;
      expect(hip.dy(body.hips.cx, body.hips.cy), lessThan(0));
      var last = -1.0;
      for (var i = 0; i <= 400; i++) {
        final y = i / 400;
        final moved = y + hip.dy(body.hips.cx, y);
        expect(moved, greaterThan(last));
        last = moved;
      }
    });

    test('sliders at zero add no warps', () {
      expect(bodyWarps(0, 0, 0, BodyAnchors.defaults), isEmpty);
      expect(bodyWarps(1, 1, 1, BodyAnchors.defaults), hasLength(4)); // waist, hips, two legs
    });
  });

  group('crop', () {
    const photo = Size(3000, 2000);

    test('a locked corner drag keeps the ratio and stays inside the photo', () {
      final k = normalizedRatio(photo, 4 / 5)!;
      final start = refitCrop(const Rect.fromLTWH(0.3, 0.1, 0.3, 0.8), k);
      final r = resizeCrop(start, 2, const Offset(0.5, 0.5), k);
      expect(cropAspect(r, photo), closeTo(0.8, 1e-6));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(1 + 1e-9));
      expect(r.bottom, lessThanOrEqualTo(1 + 1e-9));
      expect(r.topLeft, start.topLeft); // the opposite corner is the anchor
    });

    test('free drag never collapses below the minimum', () {
      final r = resizeCrop(const Rect.fromLTWH(0.2, 0.2, 0.5, 0.5), 0, const Offset(0.9, 0.9), null);
      expect(r.width, closeTo(minCropSide, 1e-9));
      expect(r.height, closeTo(minCropSide, 1e-9));
    });

    test('moving clamps to the photo', () {
      final r = moveCrop(const Rect.fromLTWH(0.5, 0.5, 0.4, 0.4), const Offset(0.5, -0.9));
      expect(r, const Rect.fromLTWH(0.6, 0, 0.4, 0.4));
    });

    test('centred crops and the Instagram range', () {
      final portrait = centeredCrop(const Size(2000, 3000), 0.8);
      expect(cropAspect(portrait, const Size(2000, 3000)), closeTo(0.8, 1e-9));
      expect(fitsFeed(2 / 3), isFalse); // a D5600 portrait shot as-is
      expect(fitsFeed(1.5), isTrue); // a D5600 landscape shot as-is
      expect(fitsFeed(9 / 16), isFalse);
    });

    test('straighten zoom covers the frame', () {
      expect(straightenScale(photo, 0), 1);
      expect(straightenScale(photo, 10), greaterThan(1.1));
    });
  });

  group('render', () {
    Future<ui.Image> solid(int w, int h) {
      final r = ui.PictureRecorder();
      Canvas(r).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366CC));
      return r.endRecording().toImage(w, h);
    }

    test('output size follows turns, crop and the long-edge cap', () async {
      final src = await solid(300, 200);
      const p = EditParams(quarterTurns: 1, crop: Rect.fromLTWH(0, 0, 1, 0.5));
      final out = await renderFinal(src, p, maxEdge: 100);
      // Turned: 200 x 300; half the height: 200 x 150; capped at 100 on the long edge.
      expect(out.width, 100);
      expect(out.height, 75);
    });

    test('story renders are 1080 x 1920 for wide and tall photos alike', () async {
      for (final (w, h) in [(400, 500), (600, 400), (90, 200)]) {
        final story = await renderStory(await solid(w, h));
        expect([story.width, story.height], [1080, 1920]);
      }
    });

    test('stretch makes the photo taller; reshape and filter paint the whole frame', () async {
      final src = await solid(120, 160);
      const p = EditParams(height: 0.3, slim: 1, hips: 1, legs: 1, filter: 'vivid');
      final out = await renderFinal(src, p);
      final h = finishedSize(const Size(120, 160), p).height.toInt();
      expect(out.width, 120);
      expect(h, greaterThan(160));
      expect(out.height, h);
      final bytes = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Corners and centre are opaque: the mesh covers the frame edge to edge.
      for (final (x, y) in [(0, 0), (119, 0), (0, h - 1), (119, h - 1), (60, h ~/ 2)]) {
        expect(bytes.getUint8((y * 120 + x) * 4 + 3), 255, reason: 'alpha at $x,$y');
      }
    });

    test('a stretched photo still keeps the long-edge cap', () async {
      final src = await solid(80, 200);
      final out = await renderFinal(src, const EditParams(height: 0.4), maxEdge: 200);
      expect(out.height, 200);
      expect(out.width, lessThan(80));
    });
  });

  group('buildPlan', () {
    final three = [
      for (final id in ['A', 'B', 'C']) _item(id),
    ];

    test('post only is one carousel', () {
      final plan = buildPlan(three, PublishMode.post);
      expect(plan.map((s) => s.kind), [StepKind.instagramPost]);
      expect(plan.single.items.map((i) => i.shotId), ['A', 'B', 'C']);
    });

    test('post + story is the carousel then a story per photo, in order', () {
      final plan = buildPlan(three, PublishMode.postAndStory);
      expect(plan.map((s) => s.kind), [
        StepKind.instagramPost,
        StepKind.instagramStory,
        StepKind.instagramStory,
        StepKind.instagramStory,
      ]);
      expect(plan.skip(1).map((s) => s.items.single.shotId), ['A', 'B', 'C']);
    });

    test('story only has no post, and Facebook only follows posts', () {
      final plan = buildPlan(three, PublishMode.story, facebook: true);
      expect(plan.every((s) => s.kind == StepKind.instagramStory), isTrue);
      final withFb = buildPlan(three, PublishMode.post, facebook: true);
      expect(withFb.map((s) => s.kind), [StepKind.instagramPost, StepKind.facebookPost]);
    });

    test('more than 10 photos split into carousels of 10', () {
      final many = [for (var i = 0; i < 23; i++) _item('P$i')];
      final plan = buildPlan(many, PublishMode.post);
      expect(plan.map((s) => s.items.length), [10, 10, 3]);
    });
  });

  group('UploadStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('shotdrop_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    UploadItem item(String id) => UploadItem(
      shotId: id,
      name: id,
      taken: DateTime(2026, 10, 21, 9, 30),
      sourcePath: '${dir.path}/s_$id.jpg',
      exportPath: '${dir.path}/e_$id.jpg',
      params: const EditParams(filter: 'mono'),
    );

    test('put, reorder, remove and caption persist across loads', () async {
      final a = UploadStore(dir: dir);
      await a.put(item('A'));
      await a.put(item('B'));
      await a.put(item('C'));
      await a.reorder(2, 0); // C to the front
      await a.remove('B');
      await a.setCaption('Sunset at Kutch');

      final b = UploadStore(dir: dir);
      await b.load();
      expect(b.queued.map((i) => i.shotId), ['C', 'A']);
      expect(b.caption, 'Sunset at Kutch');
      expect(b.contains('A'), isTrue);
      expect(b.contains('B'), isFalse);
      expect(b.byShot('C')!.params.filter, 'mono');
    });

    test('published photos leave the queue, and the caption clears with the last one', () async {
      final s = UploadStore(dir: dir);
      await s.put(item('A'));
      await s.put(item('B'));
      await s.setCaption('hi');
      await s.markPublished(['A']);
      expect(s.queued.map((i) => i.shotId), ['B']);
      expect(s.isPublished('A'), isTrue);
      expect(s.contains('A'), isFalse);
      expect(s.caption, 'hi');
      await s.markPublished(['B']);
      expect(s.queued, isEmpty);
      expect(s.caption, '');
    });

    test('re-editing replaces the item in place and deletes the old export', () async {
      final s = UploadStore(dir: dir);
      final first = item('A');
      File(first.exportPath).writeAsStringSync('old');
      await s.put(first);
      await s.put(first.copyWith(exportPath: '${dir.path}/e_A2.jpg'));
      expect(s.items, hasLength(1));
      expect(s.items.single.exportPath, endsWith('e_A2.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File(first.exportPath).existsSync(), isFalse);
    });
  });
}

UploadItem _item(String id) => UploadItem(
  shotId: id,
  name: id,
  taken: DateTime(2026),
  sourcePath: '/s/$id.jpg',
  exportPath: '/e/$id.jpg',
  params: const EditParams(),
);
