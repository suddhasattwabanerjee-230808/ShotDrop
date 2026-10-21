import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'card_channel.dart';
import 'models.dart';

enum CardState { noFolder, waiting, loading, ready, error }

/// The camera card: which folder was picked, whether it's plugged in, and the
/// shots on it. Rescans by itself when a card is plugged in or pulled out.
class CardStore extends ChangeNotifier {
  CardStore({CardChannel? channel}) : _channel = channel ?? CardChannel.instance;

  final CardChannel _channel;
  static const _folderKey = 'shotdrop.card_folder.v1';

  String? folder;
  CardState state = CardState.noFolder;
  List<CardShot> shots = const [];
  String? error;
  StreamSubscription<void>? _volumes;

  Future<void> load() async {
    folder = await SharedPreferencesAsync().getString(_folderKey).catchError((Object _) => null);
    _volumes = _channel.volumeChanges.listen((_) => refresh());
    await refresh();
  }

  Future<bool> pickFolder() async {
    final picked = await _channel.pickFolder();
    if (picked == null) return false;
    folder = picked;
    await SharedPreferencesAsync().setString(_folderKey, picked).catchError((Object _) {});
    await refresh();
    return true;
  }

  Future<void> refresh() async {
    final f = folder;
    if (f == null) {
      _set(CardState.noFolder);
      return;
    }
    try {
      switch (await _channel.access(f)) {
        case CardAccess.noPermission:
          folder = null;
          _set(CardState.noFolder);
          return;
        case CardAccess.missing:
          shots = const [];
          _set(CardState.waiting);
          return;
        case CardAccess.ok:
          if (state != CardState.ready) _set(CardState.loading);
          shots = pairShots(await _channel.list(f));
          _set(CardState.ready);
      }
    } catch (e) {
      error = '$e';
      _set(CardState.error);
    }
  }

  void _set(CardState s) {
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _volumes?.cancel();
    super.dispose();
  }
}

/// The Upload folder: edited photos waiting to be posted, in posting order,
/// plus the caption. Kept in a JSON file so it survives restarts.
class UploadStore extends ChangeNotifier {
  UploadStore({this._dir});

  Directory? _dir;
  List<UploadItem> items = [];
  String caption = '';

  Future<Directory> get dir async => _dir ??= await getApplicationSupportDirectory();
  Future<File> get _file async => File('${(await dir).path}/upload_queue.json');

  /// Where an item's files live: `sources/<id>.jpg` and `uploads/<id>-<time>.jpg`.
  Future<String> sourcePathFor(String shotId) async => '${(await dir).path}/sources/${_safe(shotId)}.jpg';
  Future<String> exportPathFor(String shotId) async =>
      '${(await dir).path}/uploads/${_safe(shotId)}-${DateTime.now().millisecondsSinceEpoch}.jpg';

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');

  List<UploadItem> get queued => [
    for (final i in items)
      if (!i.published) i,
  ];
  bool contains(String shotId) => items.any((i) => i.shotId == shotId && !i.published);
  UploadItem? byShot(String shotId) {
    for (final i in items) {
      if (i.shotId == shotId) return i;
    }
    return null;
  }

  Future<void> load() async {
    try {
      final f = await _file;
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      items = [for (final m in j['items'] as List) UploadItem.fromJson((m as Map).cast<String, Object?>())];
      caption = j['caption'] as String? ?? '';
      notifyListeners();
    } catch (e) {
      debugPrint('Upload folder unreadable, starting empty: $e');
    }
  }

  Future<void> _save() async {
    final f = await _file;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(
      jsonEncode({
        'items': [for (final i in items) i.toJson()],
        'caption': caption,
      }),
    );
    await tmp.rename(f.path);
  }

  /// Adds the photo, or replaces it if it was edited before (the old export is deleted).
  Future<void> put(UploadItem item) async {
    final i = items.indexWhere((x) => x.shotId == item.shotId);
    if (i < 0) {
      items = [...items, item];
    } else {
      final old = items[i];
      if (old.exportPath != item.exportPath) _deleteQuietly(old.exportPath);
      items = [...items]..[i] = item;
    }
    notifyListeners();
    await _save();
  }

  Future<UploadItem?> remove(String shotId) async {
    final item = byShot(shotId);
    if (item == null) return null;
    items = [
      for (final i in items)
        if (i.shotId != shotId) i,
    ];
    notifyListeners();
    await _save();
    return item;
  }

  /// Deletes an item's files once it's gone for good (after the undo window).
  void purge(UploadItem item) {
    if (byShot(item.shotId) != null) return;
    _deleteQuietly(item.exportPath);
    _deleteQuietly(item.sourcePath);
    final g = item.galleryUri;
    if (g != null) CardChannel.instance.deleteFromGallery(g).catchError((Object _) {});
  }

  /// Moves a queued item from [from] to [to] (indexes into [queued], [to] counted after the removal).
  Future<void> reorder(int from, int to) async {
    final q = queued;
    final moved = q.removeAt(from);
    q.insert(to, moved);
    items = [
      ...q,
      for (final i in items)
        if (i.published) i,
    ];
    notifyListeners();
    await _save();
  }

  Future<void> setCaption(String text) async {
    caption = text;
    await _save();
  }

  static void _deleteQuietly(String path) {
    File(path).delete().then((_) {}, onError: (Object _) {});
  }
}
