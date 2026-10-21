// Renders the main screens to PNGs with fake card data, for eyeballing the UI
// on a machine without an Android device:
//   flutter test test/preview_test.dart --dart-define=PREVIEW_DIR=/some/dir
// Skipped unless PREVIEW_DIR is set.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shotdrop/main.dart';
import 'package:shotdrop/models.dart';
import 'package:shotdrop/screens/editor_screen.dart';
import 'package:shotdrop/screens/upload_screen.dart';
import 'package:shotdrop/screens/viewer_screen.dart';
import 'package:shotdrop/stores.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const outDir = String.fromEnvironment('PREVIEW_DIR');
// Optional: a phone screenshot with a person in it, and the y range (in
// pixels) of the photo within it, used as the body tools' test photo.
const realPhoto = String.fromEnvironment('REAL_PHOTO');
const realTop = int.fromEnvironment('REAL_TOP'), realBottom = int.fromEnvironment('REAL_BOTTOM');

Future<void> _cropReal(String from, String to) async {
  final codec = await ui.instantiateImageCodec(File(from).readAsBytesSync());
  final src = (await codec.getNextFrame()).image;
  final h = realBottom - realTop;
  final r = ui.PictureRecorder();
  Canvas(r).drawImageRect(
    src,
    Rect.fromLTWH(0, realTop.toDouble(), src.width.toDouble(), h.toDouble()),
    Rect.fromLTWH(0, 0, src.width.toDouble(), h.toDouble()),
    Paint(),
  );
  final img = await r.endRecording().toImage(src.width, h);
  File(to).writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
}

Future<void> _loadFonts() async {
  final manrope = FontLoader('Manrope');
  for (final w in [400, 500, 600, 700, 800]) {
    manrope.addFont(rootBundle.load('assets/fonts/Manrope-$w.ttf'));
  }
  await manrope.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('/root/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
        ),
      ),
    );
  await icons.load();
}

/// A fake "photo": a sky-to-ground gradient with a figure in the middle.
Future<void> _writePhoto(String path, int w, int h, int seed) async {
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  final rnd = math.Random(seed);
  final hue = rnd.nextDouble() * 360;
  final sky = HSVColor.fromAHSV(1, hue, 0.45, 0.95).toColor();
  final ground = HSVColor.fromAHSV(1, (hue + 40) % 360, 0.6, 0.35).toColor();
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  c.drawRect(rect, Paint()..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [sky, ground]));
  c.drawCircle(
    Offset(w * (0.2 + rnd.nextDouble() * 0.6), h * 0.25),
    w * 0.08,
    Paint()..color = const Color(0xFFFFF2C4),
  );
  final body = Paint()..color = const Color(0xFF1B1B22);
  c.drawCircle(Offset(w * 0.5, h * 0.42), w * 0.05, body);
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.62), width: w * 0.14, height: h * 0.3),
      Radius.circular(w * 0.03),
    ),
    body,
  );
  final img = await r.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (outDir.isEmpty) {
    test('screen previews (set PREVIEW_DIR to render)', () {}, skip: true);
    return;
  }

  late Directory tmp;
  late List<CardFile> files;

  setUpAll(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({
      'shotdrop.card_folder.v1': 'content://tree/DCIM',
    });
    tmp = Directory.systemTemp.createTempSync('shotdrop_preview');
    files = [];
    final base = DateTime(2026, 10, 21, 18, 40).millisecondsSinceEpoch;
    for (var i = 0; i < 14; i++) {
      final name = 'DSC_${(412 - i).toString().padLeft(4, '0')}';
      final portrait = i % 3 == 1;
      final modified = base - i * 1000 * 60 * (i < 8 ? 7 : 400);
      final path = '${tmp.path}/card/$name.png';
      files.add(
        CardFile(uri: path, docId: 'X:DCIM/100D5600/$name.JPG', name: '$name.JPG', size: 9800000, modified: modified),
      );
      if (i % 2 == 0) {
        files.add(
          CardFile(
            uri: path,
            docId: 'X:DCIM/100D5600/$name.NEF',
            name: '$name.NEF',
            size: 24800000,
            modified: modified,
          ),
        );
      }
      // Written inside runAsync in the test, where real async work can run.
      _pending.add((path, portrait ? 400 : 600, portrait ? 600 : 400, i));
    }
  });

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      // Let file images decode, then settle.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 300));
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('preview-root')));
      final image = await boundary.toImage(pixelRatio: 1.25);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$outDir/$name.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('screens', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('shotdrop/card'),
      (call) async {
        final a = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'access':
            return 'ok';
          case 'list':
            return [
              for (final f in files)
                {'uri': f.uri, 'docId': f.docId, 'name': f.name, 'size': f.size, 'modified': f.modified},
            ];
          case 'thumbnail':
            return a['uri'];
          case 'importSource':
            File(a['dest'] as String).parent.createSync(recursive: true);
            File(a['uri'] as String).copySync(a['dest'] as String);
            return null;
          case 'encodeJpeg':
            final buffer = await ui.ImmutableBuffer.fromUint8List(a['rgba'] as Uint8List);
            final d = ui.ImageDescriptor.raw(
              buffer,
              width: a['width'] as int,
              height: a['height'] as int,
              pixelFormat: ui.PixelFormat.rgba8888,
            );
            final frame = await (await d.instantiateCodec()).getNextFrame();
            final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            File(a['dest'] as String)
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(png!.buffer.asUint8List());
            return null;
          case 'saveToGallery':
            return 'content://media/1';
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('shotdrop/pose'),
      // Where the person in REAL_PHOTO is (read off the photo by eye).
      (call) async => {
        11: [0.29, 0.40, 0.99],
        12: [0.74, 0.40, 0.99],
        23: [0.37, 0.80, 0.9],
        24: [0.66, 0.80, 0.9],
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('shotdrop/share'),
      (call) async => switch (call.method) {
        'apps' => {'instagram': true, 'facebook': true},
        'share' => 'launched',
        _ => null,
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('shotdrop/card/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    late CardStore card;
    late UploadStore uploads;
    late SocialSettings social;
    await tester.runAsync(() async {
      await _loadFonts();
      for (final (path, w, h, seed) in _pending) {
        await _writePhoto(path, w, h, seed);
      }
      // A real photo for the body tools, if one was given: it replaces shot 2's.
      if (realPhoto.isNotEmpty) await _cropReal(realPhoto, _pending[1].$1);
      card = CardStore();
      uploads = UploadStore(dir: Directory('${tmp.path}/app'));
      social = SocialSettings();
      await social.load();
      await card.load();
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('preview-root'),
        child: ShotDropApp(card: card, uploads: uploads, social: social),
      ),
    );
    await shot(tester, '0_setup');
    await tester.enterText(find.byType(TextField), 'bittu.shoots');
    await tester.tap(find.text('Continue'));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '1_grid');

    // Select a few
    await tester.longPress(find.byType(GestureDetector).at(3));
    await tester.pump();
    await tester.tap(find.byType(GestureDetector).at(5));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '2_grid_selecting');
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 300));

    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(shots: card.shots, initialIndex: 1)));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '3_viewer');

    nav.push(MaterialPageRoute<void>(builder: (_) => EditorScreen(targets: [EditTarget.fromShot(card.shots[1])])));
    await shot(tester, '4_editor_crop');

    await tester.tap(find.text('Body'));
    await shot(tester, '5_editor_body');
    for (final (tool, name) in [('Slim', '5b_slim'), ('Hip', '5c_hip'), ('Stretch', '5d_stretch')]) {
      await tester.tap(find.text(tool));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(find.byType(Slider), const Offset(400, 0)); // to 100
      await shot(tester, name);
      await tester.tap(find.text('Apply'));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await shot(tester, '5e_body_applied');

    await tester.tap(find.text('Adjust'));
    await shot(tester, '6_editor_adjust');

    await tester.tap(find.text('Done'));
    // The export is real work: wait for the editor to close by itself.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && find.byType(EditorScreen).evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
    expect(find.byType(EditorScreen), findsNothing);
    await shot(tester, '7_after_done_viewer');

    nav.push(MaterialPageRoute<void>(builder: (_) => const UploadScreen()));
    await shot(tester, '8_upload_folder');

    await tester.enterText(find.byType(TextField), 'Golden hour at the Rann of Kutch #nikon #d5600');
    await tester.tap(find.textContaining('Publish 1'));
    await shot(tester, '9_publish_sheet');
    await tester.tap(find.text('Post + Story'));
    await tester.pump();
    await shot(tester, '9b_publish_sheet_post_story');
    await tester.tap(find.text('Start'));
    await shot(tester, '10_publish_post_step');
    await tester.tap(find.text('Open Instagram'));
    await shot(tester, '11_publish_post_asking');
    await tester.tap(find.text("Yes, it's posted"));
    await shot(tester, '11b_publish_facebook_step');
    await tester.tap(find.text('Open Facebook'));
    await shot(tester, '11c_publish_facebook_asking');
    await tester.tap(find.text("Yes, it's posted"));
    await shot(tester, '12_publish_story_step');
    await tester.tap(find.text('Open Instagram'));
    // The story render (blur at 1080 x 1920) is slow on the test renderer.
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && find.text("Yes, it's posted").evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
    await shot(tester, '13_publish_story_asking');
    await tester.tap(find.text("Yes, it's posted"));
    await shot(tester, '14_publish_done');
    await tester.runAsync(() async {
      final story = Directory('${tmp.path}/app/uploads')
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('-story.jpg'));
      story.copySync('$outDir/15_story_render.png');
    });
  });
}

final _pending = <(String, int, int, int)>[];
