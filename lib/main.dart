import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/card_screen.dart';
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
  await Future.wait([uploads.load(), social.load()]);
  card.load();
  updater.check(); // in the background: a dot on the menu if there's a new version
  runApp(ShotDropApp(card: card, uploads: uploads, social: social, updater: updater));
}

class ShotDropApp extends StatelessWidget {
  const ShotDropApp({
    super.key,
    required this.card,
    required this.uploads,
    required this.social,
    required this.updater,
  });

  final CardStore card;
  final UploadStore uploads;
  final SocialSettings social;
  final Updater updater;

  @override
  Widget build(BuildContext context) => AppScope(
    card: card,
    uploads: uploads,
    social: social,
    updater: updater,
    child: MaterialApp(
      title: 'ShotDrop',
      debugShowCheckedModeBanner: false,
      theme: appThemeData(),
      // The Instagram setup comes first, on the first launch only; after that the card's photos.
      home: social.setupSeen ? const CardScreen() : const SetupScreen(firstRun: true),
    ),
  );
}
