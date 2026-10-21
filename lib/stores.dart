import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'card_channel.dart';
import 'models.dart';
import 'share_channel.dart';

enum CardState { noFolder, waiting, newCard, loading, ready, error }

/// The camera card: which folder was picked, whether it's plugged in, and the
/// shots on it. Rescans by itself when a card is plugged in or pulled out
/// (and every few seconds while waiting for one, in case the phone doesn't
/// say). A card picked before opens by itself; a new one asks once, with the
/// picker already on its DCIM folder.
class CardStore extends ChangeNotifier {
  CardStore({CardChannel? channel}) : _channel = channel ?? CardChannel.instance;

  final CardChannel _channel;
  static const _folderKey = 'shotdrop.card_folder.v1';

  String? folder;
  CardState state = CardState.noFolder;
  List<CardShot> shots = const [];
  String? error;
  String? cardName; // the plugged-in card, while it's waiting to be opened (newCard)
  StreamSubscription<void>? _volumes;
  Timer? _poll;
  bool _refreshing = false, _again = false;

  Future<void> load() async {
    folder = await SharedPreferencesAsync().getString(_folderKey).catchError((Object _) => null);
    _volumes = _channel.volumeChanges.listen((_) => refresh());
    await refresh();
  }

  Future<bool> pickFolder() async {
    final picked = await _channel.pickFolder();
    if (picked == null) return false;
    await _use(picked);
    await refresh();
    return true;
  }

  Future<void> _use(String f) async {
    folder = f;
    await SharedPreferencesAsync().setString(_folderKey, f).catchError((Object _) {});
  }

  Future<void> refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _refresh();
      } while (_again);
    } finally {
      _refreshing = false;
    }
    // Waiting for a card: look again every few seconds.
    final waiting = state == CardState.noFolder || state == CardState.waiting || state == CardState.newCard;
    if (waiting && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    } else if (!waiting) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _refresh() async {
    try {
      var f = folder;
      var access = f == null ? CardAccess.missing : await _channel.access(f);
      if (access != CardAccess.ok) {
        // Not there: another card (or folder) picked before that's plugged in now?
        final other = await _channel.findCard();
        if (other != null) {
          await _use(other);
          f = other;
          access = CardAccess.ok;
        }
      }
      if (access == CardAccess.noPermission) folder = null;
      if (access != CardAccess.ok || f == null) {
        shots = const [];
        cardName = await _channel.cardVolume();
        _set(cardName != null ? CardState.newCard : (folder == null ? CardState.noFolder : CardState.waiting));
        return;
      }
      cardName = null;
      if (state != CardState.ready) _set(CardState.loading);
      final listed = pairShots(await _channel.list(f));
      // Only tell the screens when something changed (a rescan finds the same card most of the time).
      if (state == CardState.ready && _sameShots(listed, shots)) return;
      shots = listed;
      _set(CardState.ready);
    } catch (e) {
      error = '$e';
      _set(CardState.error);
    }
  }

  static bool _sameShots(List<CardShot> a, List<CardShot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].taken != b[i].taken) return false;
    }
    return true;
  }

  void _set(CardState s) {
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _volumes?.cancel();
    _poll?.cancel();
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
  bool isPublished(String shotId) => items.any((i) => i.shotId == shotId && i.published);
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

  /// Marks photos as posted: they leave the queue (the grid shows them as
  /// POSTED) and their gallery copies move to Pictures/ShotDrop/Published.
  /// The caption is cleared once nothing is left to post.
  Future<void> markPublished(Iterable<String> shotIds) async {
    final ids = shotIds.toSet();
    items = [for (final i in items) ids.contains(i.shotId) ? i.copyWith(published: true) : i];
    if (queued.isEmpty) caption = '';
    notifyListeners();
    await _save();
    for (final i in items) {
      final g = i.galleryUri;
      if (ids.contains(i.shotId) && g != null) {
        ShareChannel.instance.moveInGallery(g, 'ShotDrop/Published').catchError((Object _) {});
      }
    }
  }

  Future<void> setCaption(String text) async {
    caption = text;
    await _save();
  }

  static void _deleteQuietly(String path) {
    File(path).delete().then((_) {}, onError: (Object _) {});
  }
}

/// The Instagram / Facebook side: who's posting, and whether Instagram
/// already shares posts to Facebook by itself (Accounts Center).
class SocialSettings extends ChangeNotifier {
  static const _handleKey = 'shotdrop.ig_handle.v1';
  static const _fbShareKey = 'shotdrop.fb_cross_post.v1';
  static const _setupKey = 'shotdrop.social_setup_seen.v1';

  String handle = '';
  bool instagramSharesToFacebook = false;
  bool setupSeen = false;

  Future<void> load() async {
    final prefs = SharedPreferencesAsync();
    handle = await prefs.getString(_handleKey).catchError((Object _) => null) ?? '';
    instagramSharesToFacebook = await prefs.getBool(_fbShareKey).catchError((Object _) => null) ?? false;
    setupSeen = await prefs.getBool(_setupKey).catchError((Object _) => null) ?? false;
    notifyListeners();
  }

  Future<void> save({String? handle, bool? instagramSharesToFacebook, bool? setupSeen}) async {
    final prefs = SharedPreferencesAsync();
    if (handle != null) {
      this.handle = handle.trim().replaceFirst(RegExp(r'^@+'), '');
      await prefs.setString(_handleKey, this.handle).catchError((Object _) {});
    }
    if (instagramSharesToFacebook != null) {
      this.instagramSharesToFacebook = instagramSharesToFacebook;
      await prefs.setBool(_fbShareKey, instagramSharesToFacebook).catchError((Object _) {});
    }
    if (setupSeen != null) {
      this.setupSeen = setupSeen;
      await prefs.setBool(_setupKey, setupSeen).catchError((Object _) {});
    }
    notifyListeners();
  }
}
