import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/edit/crop.dart';
import 'package:shotdrop/edit/filters.dart';
import 'package:shotdrop/edit/render.dart';
import 'package:shotdrop/edit/reshape.dart';
import 'package:shotdrop/models.dart';
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
      width: -0.1,
      widthBand: (0.2, 0.6),
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

    test('reshape and filter keep the frame size and paint the whole frame', () async {
      final src = await solid(120, 160);
      const p = EditParams(height: 0.3, width: -0.3, filter: 'vivid');
      final out = await renderFinal(src, p);
      expect([out.width, out.height], [120, 160]);
      final bytes = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Corners and centre are opaque: the mesh covers the frame edge to edge.
      for (final (x, y) in [(0, 0), (119, 0), (0, 159), (119, 159), (60, 80)]) {
        expect(bytes.getUint8((y * 120 + x) * 4 + 3), 255, reason: 'alpha at $x,$y');
      }
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
