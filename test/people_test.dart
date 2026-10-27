import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/edit/erase.dart';
import 'package:shotdrop/models.dart';
import 'package:shotdrop/people/model_store.dart';
import 'package:shotdrop/people/people.dart';
import 'package:shotdrop/people/remove_people.dart';

/// A finder output with one person: centred at grid cell ([gx], [gy]) of
/// [stride], [w] x [h] (in 640 px input pixels), sure as [score].
Float32List finderOut(List<(int stride, int gx, int gy, double w, double h, double score)> people) {
  final out = Float32List(8400 * 85);
  for (final (stride, gx, gy, w, h, score) in people) {
    var i = 0;
    for (final s in const [8, 16, 32]) {
      final n = 640 ~/ s;
      if (s == stride) {
        i += gy * n + gx;
        break;
      }
      i += n * n;
    }
    final o = i * 85;
    out[o] = 0.5; // centre in the middle of the cell
    out[o + 1] = 0.5;
    out[o + 2] = math.log(w / stride);
    out[o + 3] = math.log(h / stride);
    out[o + 4] = math.sqrt(score);
    out[o + 5] = math.sqrt(score);
  }
  return out;
}

Found person(double x0, double y0, double x1, double y1, [double score = 0.9]) => Found(x0, y0, x1, y1, score);

/// An outline filling [box] fully.
Outline solid(Box box) => Outline(box, Uint8List(box.w * box.h)..fillRange(0, box.w * box.h, 255));

void main() {
  group('Finding people', () {
    test('looks at the whole photo, then overlapping tiles', () {
      final small = finderRegions(1000, 700);
      expect(small.length, 1 + 4);
      expect(small.first, isA<Box>().having((b) => b.w, 'w', 1000).having((b) => b.h, 'h', 700));
      final big = finderRegions(2048, 1365);
      expect(big.length, 1 + 4 + 9);
      for (final b in big) {
        expect(b.l >= 0 && b.t >= 0 && b.r <= 2048 && b.b <= 1365, isTrue, reason: '$b');
      }
      // Every point is in some 3x3 tile with room around it.
      expect(big.skip(5).any((b) => b.l < 1000 && b.r > 1100), isTrue);
    });

    test('reads people from the finder, in photo pixels', () {
      // A 1280 x 960 photo, shrunk by 0.5 into the finder.
      final out = finderOut([(16, 20, 10, 80, 200, 0.81)]);
      final found = finderPeople(out, 0.5, const Box(0, 0, 1280, 960), 1280, 960);
      expect(found, hasLength(1));
      final f = found.single;
      // Centre (20.5, 10.5) cells of 16 = (328, 168) in the input = (656, 336) in the photo.
      expect(f.x0, closeTo(656 - 80, 0.01));
      expect(f.x1, closeTo(656 + 80, 0.01));
      expect(f.y0, closeTo(336 - 200, 0.01));
      expect(f.score, closeTo(0.81, 0.001));
      expect(finderPeople(finderOut([(8, 1, 1, 10, 10, 0.2)]), 1, const Box(0, 0, 640, 640), 640, 640), isEmpty);
    });

    test('leaves someone cut off by a tile edge to the rest', () {
      // A tile at (500, 0)..(1140, 640) of a 2000 x 1000 photo: someone touching its left edge
      // is only partly in it; touching the photo's own top edge is fine.
      final out = finderOut([(16, 1, 10, 60, 120, 0.9), (16, 20, 3, 60, 120, 0.9)]);
      final found = finderPeople(out, 1, const Box(500, 0, 1140, 640), 2000, 1000);
      expect(found, hasLength(1));
      expect(found.single.x0, greaterThan(700)); // the one in the tile's middle
    });

    test('one box per person, the bigger of two equally sure', () {
      final whole = person(100, 100, 300, 600, 0.95);
      final part = person(110, 100, 290, 350, 0.95); // a tile's view of the top half
      final dup = person(104, 98, 302, 598, 0.9);
      final other = person(500, 100, 650, 600, 0.8);
      final kept = onePerPerson([part, dup, other, whole]);
      expect(kept, [whole, other]);
    });
  });

  group('Who stays', () {
    test('the big one near the middle, and whoever poses beside them', () {
      final main = person(400, 200, 600, 900);
      final friend = person(610, 260, 790, 900); // right beside, nearly as tall
      final passerBy = person(1300, 300, 1450, 860); // as tall, but far off
      final behind = person(800, 500, 860, 700); // small, in the background
      final stays = whoStays([behind, main, passerBy, friend], 1600, 1000);
      expect(stays, {1, 3});
    });

    test('a row of friends stays together', () {
      final row = [for (var i = 0; i < 4; i++) person(200.0 + i * 220, 200, 400.0 + i * 220, 900)];
      expect(whoStays(row, 1600, 1000), {0, 1, 2, 3});
    });

    test('nobody big enough to be the subject: everyone goes', () {
      final tiny = [person(100, 500, 120, 560), person(900, 520, 918, 580)];
      expect(whoStays(tiny, 2000, 1000), isEmpty);
      expect(whoStays(const [], 2000, 1000), isEmpty);
    });
  });

  group('Outlines', () {
    test('keeps only the person\'s own blob, inside their box', () {
      // Outliner output over a crop of (0, 0)..(192, 192) at 1:1: the person (a big blob in
      // the middle) and a bit of a neighbour (a small blob at the left).
      final out = Float32List(2 * 192 * 192);
      for (var y = 0; y < 192; y++) {
        for (var x = 0; x < 192; x++) {
          final body = x >= 70 && x < 130 && y >= 20 && y < 180;
          final neighbour = x >= 52 && x < 62 && y >= 80 && y < 120;
          out[y * 192 + x] = 4; // background score
          out[192 * 192 + y * 192 + x] = body || neighbour ? 8 : 0;
        }
      }
      final o = outlineOf(person(50, 15, 140, 185), const Box(0, 0, 192, 192), out, 192, 192);
      int at(int x, int y) => o.alpha[(y - o.box.t) * o.box.w + x - o.box.l];
      expect(at(100, 100), greaterThan(200)); // the body
      expect(at(56, 100), 0); // the neighbour, though in the box
      expect(at(65, 100), lessThan(30)); // background
    });
  });

  group('Masks', () {
    test('removes the others, grown, and never touches who stays', () {
      const w = 400, h = 300;
      final keep = person(50, 50, 150, 280);
      final go = person(250, 100, 300, 250);
      final m = peopleMasks(
        [keep, go],
        [solid(const Box(60, 60, 140, 280)), solid(const Box(260, 110, 290, 250))],
        {0},
        w,
        h,
      );
      expect(m.removed, 1);
      expect(m.kept, 1);
      expect(m.remove[150 * w + 275], 255); // inside
      expect(m.remove[150 * w + 256], 255); // grown past the outline (by at least 4)
      expect(m.remove[150 * w + 100], 0);
      expect(m.keep[150 * w + 100], 255);
      expect(m.keep[150 * w + 141], 255); // grown 2
      expect(m.keep[150 * w + 145], 0);
    });

    test('someone behind the subject: their face is theirs, the subject\'s arm stays', () {
      const w = 600, h = 400;
      final subject = person(100, 40, 300, 400); // middle (200, 220)
      final behind = person(250, 120, 330, 400); // middle (290, 260), overlapping the subject's box
      // Both outlines cover the overlap (each crop sees both).
      final m = peopleMasks(
        [subject, behind],
        [solid(const Box(100, 40, 300, 400)), solid(const Box(250, 120, 330, 400))],
        {0},
        w,
        h,
      );
      // (295, 150): at the subject's edge, near the middle of the one behind (their face): theirs.
      expect(m.remove[150 * w + 295], 255);
      expect(m.keep[150 * w + 295], 0);
      // (260, 220): well inside the subject (their arm), at the other's edge: stays.
      expect(m.keep[220 * w + 260], 255);
      expect(m.remove[220 * w + 260], 0);
    });
  });

  group('Painting', () {
    test('one area per cluster, with room around it; a queue is one area', () {
      const w = 2000, h = 1000;
      final hole = Uint8List(w * h);
      void blob(int l, int t, int r, int b) {
        for (var y = t; y < b; y++) {
          hole.fillRange(y * w + l, y * w + r, 255);
        }
      }

      blob(100, 400, 160, 600);
      blob(1700, 400, 1760, 600);
      final apart = paintAreas(hole, w, h);
      expect(apart, hasLength(2));
      expect(apart.first.l, lessThan(100));
      expect(apart.first.r, greaterThan(160));
      blob(200, 400, 260, 600);
      blob(300, 400, 360, 600);
      expect(paintAreas(hole, w, h), hasLength(2)); // the three on the left are one
    });

    test('LaMa sees the hole, and only the hole is painted', () {
      const w = 100, h = 80;
      final photo = Photo(w, h, Uint8List(w * h * 4)..fillRange(0, w * h * 4, 50));
      final hole = Uint8List(w * h);
      for (var y = 30; y < 40; y++) {
        hole.fillRange(y * w + 40, y * w + 60, 255);
      }
      const area = Box(20, 10, 80, 70);
      final (image, mask) = painterInput(photo, hole, area);
      expect(image.length, 3 * 512 * 512);
      expect(image[0], closeTo(50 / 255, 1e-6));
      expect(mask[(35 - 10) * 512 ~/ 60 * 512 + (50 - 20) * 512 ~/ 60], 1);
      expect(mask[5 * 512 + 5], 0);
      final painted = Float32List(3 * 512 * 512)..fillRange(0, 3 * 512 * 512, 200);
      final out = pastePainted(photo, hole, area, painted);
      expect(out[(35 * w + 50) * 4], 200);
      expect(out[(20 * w + 50) * 4], 50);
    });
  });

  group('Turning and merging', () {
    test('turning four times, or there and back, changes nothing', () {
      const w = 7, h = 4;
      final px = Uint8List.fromList([for (var i = 0; i < w * h * 4; i++) i % 251]);
      final p = Photo(w, h, px);
      var t = p;
      for (var i = 0; i < 4; i++) {
        t = turnPhoto(t, 1);
      }
      expect(t.rgba, px);
      final once = turnPhoto(p, 1);
      expect((once.width, once.height), (h, w));
      // Clockwise: the top-left corner goes to the top-right.
      expect(once.rgba.sublist((0 * h + h - 1) * 4, (0 * h + h - 1) * 4 + 4), px.sublist(0, 4));
      expect(turnPhoto(once, 3).rgba, px);
      final plane = Uint8List.fromList([for (var i = 0; i < w * h; i++) i]);
      expect(turnPlane(turnPlane(plane, w, h, 1), h, w, 3), plane);
    });

    test('only what changed goes into the full-size photo', () {
      const w = 40, h = 30;
      final full = Photo(w * 2, h * 2, Uint8List(w * h * 16)..fillRange(0, w * h * 16, 10));
      final changed = Uint8List(w * h);
      for (var y = 10; y < 20; y++) {
        changed.fillRange(y * w + 10, y * w + 20, 255);
      }
      final result = RemoveResult(Photo(w, h, Uint8List(w * h * 4)..fillRange(0, w * h * 4, 230)), changed, 1, 0);
      final out = mergeInto(full, result);
      expect(out[(30 * w * 2 + 30) * 4], 230); // inside, at full size
      expect(out[(4 * w * 2 + 4) * 4], 10); // elsewhere: the full-size original
      expect(out[(4 * w * 2 + 4) * 4 + 3], 10); // alpha left alone
    });
  });

  test('erasing never touches or copies what\'s protected', () {
    const w = 200, h = 160;
    final rnd = math.Random(4);
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final v = 100 + rnd.nextInt(40);
      rgba.setAll(i * 4, [v, v, v, 255]);
    }
    // Someone kept, in green, right against the hole.
    final protect = Uint8List(w * h), mask = Uint8List(w * h);
    for (var y = 40; y < 120; y++) {
      for (var x = 60; x < 90; x++) {
        protect[y * w + x] = 255;
        rgba.setAll((y * w + x) * 4, [30, 200, 40, 255]);
      }
      mask.fillRange(y * w + 90, y * w + 130, 255);
    }
    final out = erase(EraseJob(width: w, height: h, rgba: rgba, mask: mask, protect: protect, grow: 6));
    for (var y = 40; y < 120; y++) {
      for (var x = 60; x < 90; x++) {
        expect(out[(y * w + x) * 4 + 1], 200, reason: 'protected pixel changed at ($x, $y)');
      }
      for (var x = 90; x < 130; x++) {
        final i = (y * w + x) * 4;
        expect(out[i + 1] - out[i], lessThan(60), reason: 'green copied to ($x, $y)');
      }
    }
  });

  group('Edit', () {
    test('keeps the people-removed copy, and can drop it', () {
      const p = EditParams(noPeople: '/x/sources/a-nopeople-1.jpg', brightness: 0.2);
      final back = EditParams.fromJson(p.toJson());
      expect(back.noPeople, p.noPeople);
      expect(p.copyWith(brightness: 0.1).noPeople, p.noPeople);
      expect(p.copyWith(noPeople: null).noPeople, isNull);
      expect(EditParams.fromJson(const EditParams().toJson()).noPeople, isNull);
      expect(const EditParams().toJson().containsKey('noPeople'), isFalse);
    });
  });

  group('Model downloads', () {
    late HttpServer server;
    late Directory dir;
    final blobs = {
      '/a': Uint8List.fromList(List.generate(3000, (i) => i % 256)),
      '/b': Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256)),
      '/c': Uint8List.fromList(List.generate(70000, (i) => (i * 13) % 256)),
    };
    var cutAfter = 0; // > 0: the next response stops after this many bytes
    final ranges = <String?>[];

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('models');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = blobs[req.uri.path]!;
        final range = req.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        var from = 0;
        if (range != null) {
          from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          req.response.statusCode = HttpStatus.partialContent;
        }
        final part = body.sublist(from);
        if (cutAfter > 0) {
          // The connection drops part way.
          final n = cutAfter;
          cutAfter = 0;
          req.response.contentLength = part.length;
          final socket = await req.response.detachSocket();
          socket.add(part.sublist(0, n));
          await socket.flush();
          socket.destroy();
          return;
        }
        req.response.add(part);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    List<ModelFile> files({bool badHash = false}) => [
      for (final (i, path) in ['/a', '/b', '/c'].indexed)
        ModelFile(
          'm$i.onnx',
          'http://127.0.0.1:${server.port}$path',
          blobs[path]!.length,
          badHash && i == 2 ? '0' * 64 : sha256.convert(blobs[path]!).toString(),
        ),
    ];

    test('downloads each once, checked, and reports progress', () async {
      final store = ModelStore(dir: dir, files: files());
      expect(await store.ready(), isFalse);
      final seen = <(int, int)>[];
      final models = await store.ensure(onProgress: (d, t) => seen.add((d, t)));
      expect(await store.ready(), isTrue);
      expect(File(models.painter).readAsBytesSync(), blobs['/c']);
      expect(seen.last, (78000, 78000));
      final calls = ranges.length;
      await store.ensure();
      expect(ranges.length, calls, reason: 'nothing fetched the second time');
    });

    test('a dropped download carries on where it got to', () async {
      final store = ModelStore(dir: dir, files: files());
      cutAfter = 1000;
      await expectLater(store.ensure(), throwsA(anything));
      await store.ensure();
      expect(ranges, contains('bytes=1000-'));
      expect(File(await store.pathOf(files()[0])).readAsBytesSync(), blobs['/a']);
    });

    test('a damaged download is thrown away', () async {
      final store = ModelStore(dir: dir, files: files(badHash: true));
      await expectLater(store.ensure(), throwsA(isA<FileSystemException>()));
      expect(File('${await store.pathOf(files()[2])}.part').existsSync(), isFalse);
      expect(await store.ready(), isFalse);
    });
  });
}
