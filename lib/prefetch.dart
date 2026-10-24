import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'card_channel.dart';
import 'faces.dart';
import 'models.dart';

/// Card photos copied off the card ahead of time (the one open in the viewer,
/// the ones picked in the gallery), so Edit and To Selected don't wait on the
/// card. They sit in the cache folder, cleared on leaving ShotDrop, until
/// [take] moves one where it belongs.
class SourcePrefetch {
  static final _jobs = <String, Future<String?>>{};

  static String _key(CardFile f) => '${f.docId}|${f.modified}|${f.size}';

  /// Starts copying [file] (once).
  static void warm(CardFile file) {
    final key = _key(file);
    _jobs.putIfAbsent(key, () async {
      try {
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/sources/${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')}.jpg';
        await File(path).parent.create(recursive: true);
        await CardChannel.instance.importSource(file, path, turn: await FaceIndex.instance.turnFor(file));
        return path;
      } catch (_) {
        _jobs.remove(key); // card pulled out: the next ask tries again
        return null;
      }
    });
  }

  /// Moves the copy of [file] made ahead to [dest], waiting for it if it's
  /// still on its way. False if there's none (or it went): copy it the usual way.
  static Future<bool> take(CardFile file, String dest) async {
    final job = _jobs.remove(_key(file));
    final path = await job;
    if (path == null) return false;
    try {
      await File(dest).parent.create(recursive: true);
      await File(path).rename(dest);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Forgets the copies (their files are cleared with the other caches).
  static void clear() => _jobs.clear();
}
