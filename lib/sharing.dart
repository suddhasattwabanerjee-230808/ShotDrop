import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'card_channel.dart';
import 'models.dart';
import 'share_channel.dart';
import 'turn.dart';

/// Gallery photos to Android's share sheet (WhatsApp, Bluetooth, Drive,
/// Messages…), as ShotDrop shows them: turned (see turnOf), under the
/// camera's file names. Each is copied off the card (or out of the phone's
/// gallery) into files/share, not the cache: the cache is cleared as
/// ShotDrop goes behind the share sheet, while the other app still has to
/// read them. Each share clears the last one's copies. RAW-only shots are
/// left out. True if the share sheet opened.
Future<bool> shareShots(BuildContext context, List<CardShot> shots) async {
  final files = [
    for (final s in shots)
      if (s.jpg case final f?) f,
  ];
  if (files.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);
  HapticFeedback.selectionClick();
  final done = ValueNotifier(0);
  final busy = messenger.showSnackBar(
    SnackBar(
      duration: const Duration(minutes: 10),
      persist: false,
      content: ValueListenableBuilder(
        valueListenable: done,
        builder: (context, n, _) => Text(
          files.length == 1 ? 'Getting The Photo Ready…' : 'Getting Photos Ready… $n Of ${files.length}',
        ),
      ),
    ),
  );
  try {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/share');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final paths = <String>[];
    final names = <String>{};
    for (final f in files) {
      final stem = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
      var name = '$stem.jpg';
      for (var i = 2; !names.add(name); i++) {
        name = '$stem-$i.jpg';
      }
      final path = '${dir.path}/$name';
      await CardChannel.instance.importSource(f, path, turn: turnOf(f));
      paths.add(path);
      done.value++;
    }
    busy.close();
    final opened = await ShareChannel.instance.shareAny(paths);
    if (!opened) messenger.showSnackBar(const SnackBar(content: Text('No App On This Phone Can Take Photos')));
    return opened;
  } catch (e) {
    busy.close();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          files.any((f) => !f.onPhone)
              ? 'Couldn\'t Get The Photos Ready. Is The Card Still In?'
              : 'Couldn\'t Get The Photos Ready',
        ),
      ),
    );
    return false;
  }
}
