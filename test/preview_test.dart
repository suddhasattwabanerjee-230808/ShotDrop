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
import 'package:shotdrop/screens/viewer_screen.dart';
import 'package:shotdrop/stores.dart';
import 'package:shotdrop/update.dart';
import 'package:shotdrop/widgets.dart';

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
    var phoneAllowed = false;
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
          case 'phoneAccess':
            return phoneAllowed ? 'all' : 'none';
          case 'requestPhoneAccess':
            phoneAllowed = true;
            return 'all';
          case 'phoneList':
            return [
              for (final (i, f) in files.where((f) => f.name.endsWith('.JPG')).take(7).indexed)
                {'uri': f.uri, 'docId': 'phone:$i', 'name': 'IMG_2026102$i.jpg', 'size': f.size, 'modified': f.modified - i * 86400000},
            ];
          case 'saveToGallery':
            return 'content://media/1';
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('shotdrop/pose'),
      (call) async {
        // The outline: the fake photos' figure is the only near-black thing in them.
        final args = call.arguments as Map;
        final rgba = args['rgba'] as Uint8List;
        final mask = Uint8List(rgba.length ~/ 4);
        for (var i = 0; i < mask.length; i++) {
          if (rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2] < 120) mask[i] = 255;
        }
        return {
          // Where the person in REAL_PHOTO is (read off the photo by eye).
          'landmarks': {
            11: [0.29, 0.40, 0.99],
            12: [0.74, 0.40, 0.99],
            23: [0.37, 0.80, 0.9],
            24: [0.66, 0.80, 0.9],
          },
          'mask': mask,
          'maskWidth': args['width'],
          'maskHeight': args['height'],
        };
      },
    );
    // Saved settings: the card folder was picked before.
    final prefs = <String, Object?>{'shotdrop.card_folder.v1': 'content://tree/DCIM'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('shotdrop/app'),
      (call) async => switch (call.method) {
        'prefs' => prefs,
        'setPref' => prefs[(call.arguments as Map)['key'] as String] = (call.arguments as Map)['value'],
        'version' => {'name': '0.6.0', 'code': 10},
        'freeSpace' => 50000000000,
        'tidyNotes' => 0,
        _ => null,
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
        child: ShotDropApp(card: card, phone: PhoneStore(), uploads: uploads, social: social, updater: Updater(), settings: AppSettings()),
      ),
    );
    await shot(tester, '0_setup');
    await tester.enterText(find.byType(TextField), 'bittu.shoots');
    await tester.tap(find.text('Continue'));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '1_grid');

    // Pick a few and keep them in Selected
    await tester.longPress(find.byType(CardImage).at(0));
    await tester.pump();
    await tester.tap(find.byType(CardImage).at(2));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '2_grid_selecting');
    await tester.tap(find.text('To Selected'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400)); // the bar slides back in
    Finder bar(IconData icon) => find.descendant(of: find.byType(BackdropFilter), matching: find.byIcon(icon));
    await tester.tap(bar(Icons.favorite_border_rounded));
    await shot(tester, '2b_selected');
    await tester.tap(bar(Icons.settings_outlined));
    await shot(tester, '2c_settings');
    // The Phone Gallery: asks first, then the phone's photos.
    await tester.tap(bar(Icons.photo_library_outlined));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await shot(tester, '2d_phone_ask');
    await tester.tap(find.text('Allow Access'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await shot(tester, '2e_phone_gallery');
    await tester.tap(find.byIcon(Icons.calendar_month_rounded).last);
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '2f_date_sheet');
    await tester.tap(find.text('Last 7 Days'));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '2g_phone_last_week');
    await tester.tap(bar(Icons.sd_card_outlined));
    await tester.pump(const Duration(milliseconds: 300));

    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(shots: card.shots, initialIndex: 1)));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '3_viewer');

    nav.push(MaterialPageRoute<void>(builder: (_) => EditorScreen(targets: [EditTarget.fromShot(card.shots[1])])));
    await shot(tester, '4_editor_crop');
    // The photo moves under the frame.
    final stage = tester.getCenter(find.byType(CustomPaint).first);
    final g = await tester.startGesture(stage);
    await g.moveBy(const Offset(0, 30));
    await g.moveBy(const Offset(0, 30));
    await tester.pump();
    await shot(tester, '4b_crop_moving');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '4c_crop_moved');
    // A corner pulled in: when it's let go, the frame stays there and only the crop shows.
    final corner = await tester.startGesture(const Offset(30, 184)); // the frame's top-left corner
    await corner.moveBy(const Offset(40, 50));
    await corner.moveBy(const Offset(40, 50));
    await tester.pump();
    await shot(tester, '4d_crop_corner_moving');
    await corner.up();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '4e_crop_corner_done');

    await tester.tap(find.text('Body'));
    await shot(tester, '5_editor_body');
    await tester.tap(find.text('Slim'));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '5a_slim_select');
    await tester.tap(find.byIcon(Icons.check_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(Slider), const Offset(160, 0)); // to about +0.6
    await shot(tester, '5b_slim');
    for (final (tool, name) in [('Hip', '5c_hip'), ('Stretch', '5d_stretch')]) {
      await tester.tap(find.text(tool));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(find.byType(Slider), const Offset(400, 0)); // to 100
      await shot(tester, name);
    }
    // Straight from a body tool to Adjust: the filters work on top of the body changes.
    await tester.tap(find.text('Adjust'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Vivid').first);
    await shot(tester, '6_editor_adjust');
    await tester.tap(find.text('Body'));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '5e_body_applied');
    // Crop after the body tools: the frame shows the slimmed photo.
    await tester.tap(find.text('Crop'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await shot(tester, '5f_crop_after_body');

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

    nav.pop(); // the viewer, back to the Gallery
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(bar(Icons.outbox_outlined));
    await shot(tester, '8_upload_folder');

    await tester.enterText(find.byType(TextField), 'Golden hour at the Rann of Kutch #nikon #d5600');
    await tester.tap(find.textContaining('Publish 1'));
    await shot(tester, '9_publish_sheet');
    await tester.tap(find.text('Post + Story'));
    await tester.pump();
    await shot(tester, '9b_publish_sheet_post_story');
    await tester.tap(find.text('Start'));
    // Start goes straight out to Instagram: the sheet closes by itself.
    Future<void> settle(bool Function() done) => tester.runAsync(() async {
      for (var i = 0; i < 900 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (!done()) debugPrint('STUCK: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | ')}');
    });
    await settle(() => find.byType(BottomSheet).evaluate().isEmpty);
    expect(uploads.session, isNotNull);
    // Back from Instagram: "Did It Post?"
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await shot(tester, '10_did_it_post');
    await tester.tap(find.text('Yes, Open The Next One'));
    bool ready(String step, String yes) =>
        find.text(step).evaluate().isNotEmpty &&
        find.text(yes).evaluate().isNotEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty;
    await settle(() => ready('Step 2 Of 3', 'Yes, Open The Next One'));
    await shot(tester, '11_did_it_post_facebook');
    await tester.tap(find.text('Yes, Open The Next One'));
    // The story render (blur at 1080 x 1920) is slow on the test renderer.
    await settle(() => ready('Step 3 Of 3', "Yes, It's Posted"));
    await shot(tester, '12_did_it_post_story');
    await tester.tap(find.text("Yes, It's Posted"));
    await settle(() => find.text('Posted To Instagram').evaluate().isNotEmpty);
    await shot(tester, '14_publish_done');
    expect(uploads.session, isNull);
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
