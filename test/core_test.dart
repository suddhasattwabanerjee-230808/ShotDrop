import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/edit/body.dart';
import 'package:shotdrop/edit/crop.dart';
import 'package:shotdrop/edit/filters.dart';
import 'package:shotdrop/edit/render.dart';
import 'package:shotdrop/edit/reshape.dart';
import 'package:shotdrop/edit/shape.dart';
import 'package:shotdrop/edit/story.dart';
import 'package:shotdrop/models.dart';
import 'package:shotdrop/publish.dart';
import 'package:shotdrop/stores.dart';
import 'package:shotdrop/update.dart';

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
      slims: [SlimArea(0.45, 0.3, 0.7, 0.6), SlimArea(0.3, 0.35, 0.65, -0.2)],
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

  test("0.3.0's Slim loads as a Slim line across the waist", () {
    final p = EditParams.fromJson({'slim': 0.5});
    expect(p.slims, hasLength(1));
    expect(p.slims.single.amount, 0.5);
    expect(p.slims.single.y, BodyAnchors.defaults.waist.cy);
    expect(EditParams.fromJson({}).slims, isEmpty);
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

    test('a local warp pulls edges in, leaves far-away pixels alone, and never folds over', () {
      const area = BodyArea(0.5, 0.4, 0.2, 0.12);
      final slim = LocalWarp(area, maxLegs);
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

    test('sliders at zero add no warps', () {
      expect(bodyWarps(0, 0, BodyAnchors.defaults), isEmpty);
      expect(bodyWarps(1, 1, BodyAnchors.defaults), hasLength(3)); // hips, two legs
    });
  });

  group('slim', () {
    const area = SlimArea(0.5, 0.3, 0.7, 1);

    test('each bracket pushes its side in, the middle and the far photo stay', () {
      expect(area.dx(0.3, 0.5, 1), closeTo(maxSlimPush * 0.4, 1e-9)); // left bracket moves right
      expect(area.dx(0.7, 0.5, 1), closeTo(-maxSlimPush * 0.4, 1e-9)); // right bracket moves left
      expect(area.dx(0.5, 0.5, 1).abs(), lessThan(1e-9)); // middle
      expect(area.dx(0.02, 0.5, 1), 0); // beyond the circles (radius 0.26)
      expect(area.dx(0.3, 0.78, 1), 0); // below them
      expect(area.copyWith(amount: -1).dx(0.3, 0.5, 1), lessThan(0)); // wider pushes out
      expect(area.copyWith(amount: 0).dx(0.3, 0.5, 1), 0);
    });

    test('the circles are round on a tall photo', () {
      // 4:5: a step of 0.1 of the height down is 0.125 of the width.
      expect(area.dx(0.3, 0.6, 0.8), closeTo(area.dx(0.425, 0.5, 0.8), 1e-9));
    });

    test('no row folds over itself, slimmer or wider', () {
      for (final a in [1.0, -1.0]) {
        final s = area.copyWith(amount: a);
        for (var v = 0.3; v <= 0.7; v += 0.05) {
          var last = -1.0;
          for (var i = 0; i <= 400; i++) {
            final u = i / 400, moved = u + s.dx(u, v, 0.8);
            expect(moved, greaterThan(last));
            last = moved;
          }
        }
      }
    });

    test('the line starts on the waist with brackets on the outline', () {
      final mask = _personMask(200, 200);
      final s = placeSlim(BodyAnchors.defaults, mask);
      expect(s.y, BodyAnchors.defaults.waist.cy);
      expect(s.left, closeTo(0.4, 0.01));
      expect(s.right, closeTo(0.6, 0.01));
      // No outline: around the pose's waist.
      final guess = placeSlim(BodyAnchors.defaults, null);
      expect(guess.left, lessThan(0.5));
      expect(guess.right, greaterThan(0.5));
    });

    test('edges are found on the body run nearest the line', () {
      final mask = _personMask(200, 200);
      expect(mask.edgesAt(0.1, 0.5), (0.425, 0.575)); // the head
      expect(mask.edgesAt(0.02, 0.5), isNull); // above it
    });

    test('the mask shrinks to at most 256 cells on its long edge', () {
      final big = BodyMask.fit(720, 900, Uint8List(720 * 900)..fillRange(0, 720 * 450, 255));
      expect(big.h, 256);
      expect(big.w, 205);
      expect(big.at(100, 10), isTrue);
      expect(big.at(100, 200), isFalse);
    });
  });

  group('updates', () {
    test('versions compare by number, not as text', () {
      expect(compareVersions('v0.10.0', '0.9.3'), 1);
      expect(compareVersions('0.4.0', 'v0.4.0'), 0);
      expect(compareVersions('0.4.0+4', '0.4.1'), -1);
    });

    test('a newer release with an APK is offered; the same or older one is not', () {
      const json = '''{"tag_name": "v0.5.0", "body": "Notes", "assets": [
        {"name": "notes.txt", "browser_download_url": "https://x/notes.txt", "size": 1},
        {"name": "ShotDrop-v0.5.0.apk", "browser_download_url": "https://x/a.apk", "size": 55000000}]}''';
      final r = Updater.parseRelease(json, '0.4.0')!;
      expect(r.version, '0.5.0');
      expect(r.apkUrl, 'https://x/a.apk');
      expect(r.apkSize, 55000000);
      expect(Updater.parseRelease(json, '0.5.0'), isNull);
      expect(Updater.parseRelease('{"tag_name": "v0.6.0", "assets": []}', '0.5.0'), isNull);
    });
  });

  test('re-cropping keeps Slim, Stretch and the body on the same part of the photo', () {
    const prev = EditParams(
      crop: Rect.fromLTWH(0, 0, 1, 1),
      slims: [SlimArea(0.5, 0.4, 0.6, 1)],
      heightBand: (0.5, 0.9),
      body: BodyAnchors.defaults,
    );
    final next = followCrop(prev, prev.copyWith(crop: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5)));
    final s = next.slims.single;
    expect([s.y, s.left, s.right], [0.5, closeTo(0.3, 1e-9), closeTo(0.7, 1e-9)]);
    expect(next.heightBand.$1, closeTo(0.5, 1e-9));
    expect(next.heightBand.$2, 1.0); // 1.3 is below the new crop: clamped
    expect(next.body!.waist.rx, closeTo(BodyAnchors.defaults.waist.rx * 2, 1e-9));
    // Turning the photo isn't a re-crop: left as it is.
    final turned = prev.copyWith(quarterTurns: 1, crop: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5));
    expect(followCrop(prev, turned).slims.single.left, 0.4);
  });

  test('settings that can\'t be read come back empty instead of hanging start-up', () async {
    TestWidgetsFlutterBinding.ensureInitialized(); // no 'shotdrop/app' handler: the call fails
    final p = await prefs().timeout(const Duration(seconds: 5));
    expect(p.getString('shotdrop.card_folder.v1'), isNull);
    expect(p.getBool('anything'), isNull);
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

    test('reshape and filter keep the frame size and paint the whole frame', () async {
      final src = await solid(120, 160);
      const p = EditParams(height: 0.3, slims: [SlimArea(0.5, 0.3, 0.7, 1)], hips: 1, legs: 1, filter: 'vivid');
      final out = await renderFinal(src, p);
      expect([out.width, out.height], [120, 160]);
      final bytes = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Corners and centre are opaque: the mesh covers the frame edge to edge.
      for (final (x, y) in [(0, 0), (119, 0), (0, 159), (119, 159), (60, 80)]) {
        expect(bytes.getUint8((y * 120 + x) * 4 + 3), 255, reason: 'alpha at $x,$y');
      }
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

    test('after publishing, posted photos are marked and the rest go back to Selected', () async {
      final s = UploadStore(dir: dir);
      await s.put(item('A'));
      await s.put(item('B'));
      await s.setCaption('hi');
      await s.finishPublishing([]); // nothing posted: nothing moves
      expect(s.queued.map((i) => i.shotId), ['A', 'B']);
      expect(s.caption, 'hi');
      await s.finishPublishing(['A']);
      expect(s.isPublished('A'), isTrue);
      expect(s.queued, isEmpty);
      expect(s.isSelected('B'), isTrue);
      expect(s.byShot('B')!.edited, isTrue); // keeps its edit for later
      expect(s.caption, '');
    });

    test('editing a Selected photo moves it to the end of the Upload folder', () async {
      final s = UploadStore(dir: dir);
      await s.put(item('A'));
      await s.put(item('B').copyWith(status: ItemStatus.selected));
      expect(s.selected.map((i) => i.shotId), ['B']);
      await s.put(item('B'));
      expect(s.queued.map((i) => i.shotId), ['A', 'B']);
      expect(s.selected, isEmpty);
      await s.move(['A'], ItemStatus.selected);
      expect(s.queued.map((i) => i.shotId), ['B']);
      expect(s.isSelected('A'), isTrue);
    });

    test('0.4 files load: published or in the Upload folder', () {
      final old = {..._item('A').toJson()..remove('status'), 'published': true};
      expect(UploadItem.fromJson(old).status, ItemStatus.published);
      expect(UploadItem.fromJson({...old, 'published': false}).status, ItemStatus.queued);
    });

    test('re-editing replaces the item in place and deletes the old export', () async {
      final s = UploadStore(dir: dir);
      final first = item('A');
      File(first.exportPath!).writeAsStringSync('old');
      await s.put(first);
      await s.put(first.copyWith(exportPath: '${dir.path}/e_A2.jpg'));
      expect(s.items, hasLength(1));
      expect(s.items.single.exportPath, endsWith('e_A2.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File(first.exportPath!).existsSync(), isFalse);
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

/// A [w] x [h] person outline: a head (30 wide) near the top, then a body 40
/// wide down to the bottom, centred.
BodyMask _personMask(int w, int h) {
  final data = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final half = y < h * 0.05 ? 0 : (y < h * 0.22 ? w * 0.075 : (y < h * 0.25 ? 0 : w * 0.1));
    for (var x = 0; x < w; x++) {
      if ((x + 0.5 - w / 2).abs() < half) data[y * w + x] = 255;
    }
  }
  return BodyMask(w, h, data);
}
