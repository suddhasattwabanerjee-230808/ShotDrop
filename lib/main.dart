import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_shell.dart';
import 'screens/setup_screen.dart';
import 'stores.dart';
import 'theme.dart';
import 'update.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final card = CardStore();
  final uploads = UploadStore();
  final social = SocialSettings();
  final updater = Updater();
  final settings = AppSettings();
  await Future.wait([uploads.load(), social.load(), settings.load()]);
  card.load();
  // In the background: a dot on Settings if there's a new version.
  if (settings.checkUpdates) updater.check();
  runApp(ShotDropApp(card: card, uploads: uploads, social: social, updater: updater, settings: settings));
}

class ShotDropApp extends StatelessWidget {
  const ShotDropApp({
    super.key,
    required this.card,
    required this.uploads,
    required this.social,
    required this.updater,
    required this.settings,
  });

  final CardStore card;
  final UploadStore uploads;
  final SocialSettings social;
  final Updater updater;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) => AppScope(
    card: card,
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
