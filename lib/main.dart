import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/card_screen.dart';
import 'screens/setup_screen.dart';
import 'stores.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final card = CardStore();
  final uploads = UploadStore();
  final social = SocialSettings();
  await Future.wait([uploads.load(), social.load()]);
  card.load();
  runApp(ShotDropApp(card: card, uploads: uploads, social: social));
}

class ShotDropApp extends StatelessWidget {
  const ShotDropApp({super.key, required this.card, required this.uploads, required this.social});

  final CardStore card;
  final UploadStore uploads;
  final SocialSettings social;

  @override
  Widget build(BuildContext context) => AppScope(
    card: card,
    uploads: uploads,
    social: social,
    child: MaterialApp(
      title: 'ShotDrop',
      debugShowCheckedModeBanner: false,
      theme: appThemeData(),
      // The Instagram setup comes first, once.
      home: social.setupSeen ? const CardScreen() : const SetupScreen(firstRun: true),
    ),
  );
}
