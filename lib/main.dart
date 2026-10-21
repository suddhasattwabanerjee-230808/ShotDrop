import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/card_screen.dart';
import 'stores.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final card = CardStore();
  final uploads = UploadStore();
  await uploads.load();
  card.load();
  runApp(ShotDropApp(card: card, uploads: uploads));
}

class ShotDropApp extends StatelessWidget {
  const ShotDropApp({super.key, required this.card, required this.uploads});

  final CardStore card;
  final UploadStore uploads;

  @override
  Widget build(BuildContext context) => AppScope(
    card: card,
    uploads: uploads,
    child: MaterialApp(
      title: 'ShotDrop',
      debugShowCheckedModeBanner: false,
      theme: appThemeData(),
      home: const CardScreen(),
    ),
  );
}
