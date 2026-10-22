import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_channel.dart';
import 'screens/home_shell.dart';
import 'screens/setup_screen.dart';
import 'stores.dart';
import 'theme.dart';
import 'update.dart';
import 'widgets.dart';

/// Whatever goes wrong while starting, the app still opens: each step has
/// a time limit, and errors are noted in Download (ShotDrop-crash-…-dart.txt)
/// rather than leaving a black screen.
Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      reportError(details.exception, details.stack);
    };
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final card = CardStore();
    final uploads = UploadStore();
    final social = SocialSettings();
    final updater = Updater();
    final settings = AppSettings();
    for (final (name, step) in [('Upload folder', uploads.load), ('Instagram', social.load), ('settings', settings.load)]) {
      try {
        await step().timeout(const Duration(seconds: 5));
      } catch (e, st) {
        reportError('Starting up ($name): $e', st);
      }
    }
    card.load();
    // In the background: a dot on Settings if there's a new version.
    if (settings.checkUpdates) updater.check();
    runApp(ShotDropApp(card: card, phone: PhoneStore(), uploads: uploads, social: social, updater: updater, settings: settings));
  }, reportError);
}

class ShotDropApp extends StatelessWidget {
  const ShotDropApp({
    super.key,
    required this.card,
    required this.phone,
    required this.uploads,
    required this.social,
    required this.updater,
    required this.settings,
  });

  final CardStore card;
  final PhoneStore phone;
  final UploadStore uploads;
  final SocialSettings social;
  final Updater updater;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) => AppScope(
    card: card,
    phone: phone,
    uploads: uploads,
    social: social,
    updater: updater,
    settings: settings,
    child: MaterialApp(
      title: 'ShotDrop',
      debugShowCheckedModeBanner: false,
      theme: appThemeData(),
      // The Instagram setup comes first, on the first launch only; after that the card's photos.
      home: social.setupSeen ? const HomeShell() : const SetupScreen(firstRun: true),
    ),
  );
}
