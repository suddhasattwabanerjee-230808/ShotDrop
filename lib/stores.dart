import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'card_channel.dart';
import 'models.dart';
import 'share_channel.dart';

/// The app's saved settings: Android's plain SharedPreferences file. (Not
/// SharedPreferencesAsync: its DataStore didn't survive R8 in release builds,
/// and every setting, from the Instagram username to the card folder, was
/// lost on restart.)
Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

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
    folder = (await prefs()).getString(_folderKey);
    _volumes = _channel.volumeChanges.listen((_) => refresh());
    // The phone doesn't always say when a USB card comes or goes, so look every few seconds too.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    await refresh();
  }

  /// With photos showing, only checks the card's still there (one small
  /// query); otherwise looks for a card again.
  Future<void> _tick() async {
    final f = folder;
    if (_refreshing) return;
    if (state == CardState.ready && f != null) {
      final here = await _channel.access(f).catchError((Object _) => CardAccess.missing);
      if (here == CardAccess.ok) return;
    }
    if (state == CardState.ready || state == CardState.noFolder || state == CardState.waiting || state == CardState.newCard) {
      await refresh();
    }
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
    await (await prefs()).setString(_folderKey, f);
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

/// The photos ShotDrop keeps, with the caption. Each is in Selected (the
/// shortlist: picked from the card, or set aside to post later), the Upload
/// folder (edited, going out next, in posting order) or posted. Kept in a
/// JSON file so it survives restarts; the photos themselves are copied off
/// the card, so Selected and Upload work with the card unplugged.
class UploadStore extends ChangeNotifier {
  UploadStore({this._dir, CardChannel? card}) : _card = card ?? CardChannel.instance;

  Directory? _dir;
  final CardChannel _card;
  List<UploadItem> items = [];
  String caption = '';
  int copying = 0; // photos still being copied off the card into Selected

  Future<Directory> get dir async => _dir ??= await getApplicationSupportDirectory();
  Future<File> get _file async => File('${(await dir).path}/upload_queue.json');

  /// Where an item's files live: `sources/<id>.jpg` and `uploads/<id>-<time>.jpg`.
  Future<String> sourcePathFor(String shotId) async => '${(await dir).path}/sources/${_safe(shotId)}.jpg';
  Future<String> exportPathFor(String shotId) async =>
      '${(await dir).path}/uploads/${_safe(shotId)}-${DateTime.now().millisecondsSinceEpoch}.jpg';

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');

  List<UploadItem> _with(ItemStatus s) => [
    for (final i in items)
      if (i.status == s) i,
  ];
  List<UploadItem> get queued => _with(ItemStatus.queued);

  /// Selected, most recently added first.
  List<UploadItem> get selected => _with(ItemStatus.selected).reversed.toList();

  bool contains(String shotId) => items.any((i) => i.shotId == shotId && i.status == ItemStatus.queued);
  bool isSelected(String shotId) => items.any((i) => i.shotId == shotId && i.status == ItemStatus.selected);
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

  /// Adds card [shots] to Selected, copying each off the card first (so they
  /// stay when it's unplugged). Ones already in Selected or the Upload folder
  /// are left where they are; posted ones come back. Returns how many were added.
  Future<int> select(List<CardShot> shots) async {
    final todo = [
      for (final s in shots)
        if (s.jpg != null && (byShot(s.id)?.published ?? true)) s,
    ];
    copying += todo.length;
    notifyListeners();
    var added = 0;
    for (final s in todo) {
      try {
        final existing = byShot(s.id);
        final path = existing?.sourcePath ?? await sourcePathFor(s.id);
        // A posted photo's files may have been cleared (Settings > Storage): copy it again.
        if (!await File(path).exists()) {
          await File(path).parent.create(recursive: true);
          await _card.importSource(s.jpg!, path);
        }
        if (existing != null) {
          await _replace(existing.copyWith(status: ItemStatus.selected));
        } else {
          items = [
            ...items,
            UploadItem(shotId: s.id, name: s.name, taken: s.taken, sourcePath: path, status: ItemStatus.selected),
          ];
        }
        added++;
      } catch (e) {
        debugPrint('Couldn\'t copy ${s.name} into Selected: $e'); // card pulled out mid-way, most likely
      } finally {
        copying--;
        notifyListeners();
      }
    }
    await _save();
    return added;
  }

  Future<void> _replace(UploadItem item) async {
    items = [for (final i in items) i.shotId == item.shotId ? item : i];
    notifyListeners();
    await _save();
  }

  /// Adds the photo, or replaces it if it was edited before (the old export is deleted).
  Future<void> put(UploadItem item) async {
    final i = items.indexWhere((x) => x.shotId == item.shotId);
    if (i < 0) {
      items = [...items, item];
    } else {
      final old = items[i];
      final oldExport = old.exportPath;
      if (oldExport != null && oldExport != item.exportPath) _deleteQuietly(oldExport);
      // Edited out of Selected: it joins the end of the posting order.
      items = old.status == item.status ? ([...items]..[i] = item) : [...items..removeAt(i), item];
    }
    notifyListeners();
    await _save();
  }

  /// Moves photos to [status] (e.g. Upload folder → Selected, to post later).
  Future<void> move(Iterable<String> shotIds, ItemStatus status) async {
    final ids = shotIds.toSet();
    items = [
      for (final i in items)
        if (!ids.contains(i.shotId)) i,
      for (final i in items)
        if (ids.contains(i.shotId)) i.copyWith(status: status),
    ];
    if (queued.isEmpty) caption = '';
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
    final export = item.exportPath;
    if (export != null) _deleteQuietly(export);
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
        if (i.status != ItemStatus.queued) i,
    ];
    notifyListeners();
    await _save();
  }

  /// After a round of publishing: [posted] photos are marked posted (the grid
  /// shows POSTED; their gallery copies move to Pictures/ShotDrop/Published),
  /// and whatever else was in the Upload folder goes back to Selected, with
  /// its edit, to post later. Nothing moves if nothing was posted.
  Future<void> finishPublishing(Iterable<String> posted) async {
    final ids = posted.toSet();
    if (ids.isEmpty) return;
    items = [
      for (final i in items)
        ids.contains(i.shotId)
            ? i.copyWith(status: ItemStatus.published)
            : i.status == ItemStatus.queued
            ? i.copyWith(status: ItemStatus.selected)
            : i,
    ];
    caption = '';
    notifyListeners();
    await _save();
    for (final i in items) {
      final g = i.galleryUri;
      if (ids.contains(i.shotId) && g != null) {
        ShareChannel.instance.moveInGallery(g, 'ShotDrop/Published').catchError((Object _) {});
      }
    }
  }

  /// Deletes the copies kept for posted photos (they stay marked POSTED).
  /// Returns how many bytes that freed.
  Future<int> clearPosted() async {
    var freed = 0;
    for (final i in items) {
      if (!i.published) continue;
      for (final path in [i.sourcePath, ?i.exportPath]) {
        final f = File(path);
        if (await f.exists()) {
          freed += await f.length();
          await f.delete().catchError((Object _) => f);
        }
      }
    }
    return freed;
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
    final p = await prefs();
    handle = p.getString(_handleKey) ?? '';
    instagramSharesToFacebook = p.getBool(_fbShareKey) ?? false;
    setupSeen = p.getBool(_setupKey) ?? false;
    notifyListeners();
  }

  Future<void> save({String? handle, bool? instagramSharesToFacebook, bool? setupSeen}) async {
    final p = await prefs();
    if (handle != null) {
      this.handle = handle.trim().replaceFirst(RegExp(r'^@+'), '');
      await p.setString(_handleKey, this.handle);
    }
    if (instagramSharesToFacebook != null) {
      this.instagramSharesToFacebook = instagramSharesToFacebook;
      await p.setBool(_fbShareKey, instagramSharesToFacebook);
    }
    if (setupSeen != null) {
      this.setupSeen = setupSeen;
      await p.setBool(_setupKey, setupSeen);
    }
    notifyListeners();
  }
}

/// How the app behaves (the Settings tab).
class AppSettings extends ChangeNotifier {
  static const _prefix = 'shotdrop.settings.';

  bool portraitAt45 = true; // portrait shots start cropped to Instagram's 4:5
  int saveEdge = 2160; // long edge of saved edits, in pixels (1080 = Instagram's own size)
  bool galleryCopy = true; // also put edits in Pictures/ShotDrop
  String publishMode = 'post'; // a PublishMode name: what the Publish sheet starts on
  bool checkUpdates = true; // look for a new version at launch

  Future<void> load() async {
    final p = await prefs();
    portraitAt45 = p.getBool('${_prefix}portraitAt45') ?? portraitAt45;
    saveEdge = p.getInt('${_prefix}saveEdge') ?? saveEdge;
    galleryCopy = p.getBool('${_prefix}galleryCopy') ?? galleryCopy;
    publishMode = p.getString('${_prefix}publishMode') ?? publishMode;
    checkUpdates = p.getBool('${_prefix}checkUpdates') ?? checkUpdates;
    notifyListeners();
  }

  Future<void> set({bool? portraitAt45, int? saveEdge, bool? galleryCopy, String? publishMode, bool? checkUpdates}) async {
    final p = await prefs();
    if (portraitAt45 != null) {
      this.portraitAt45 = portraitAt45;
      await p.setBool('${_prefix}portraitAt45', portraitAt45);
    }
    if (saveEdge != null) {
      this.saveEdge = saveEdge;
      await p.setInt('${_prefix}saveEdge', saveEdge);
    }
    if (galleryCopy != null) {
      this.galleryCopy = galleryCopy;
      await p.setBool('${_prefix}galleryCopy', galleryCopy);
    }
    if (publishMode != null) {
      this.publishMode = publishMode;
      await p.setString('${_prefix}publishMode', publishMode);
    }
    if (checkUpdates != null) {
      this.checkUpdates = checkUpdates;
      await p.setBool('${_prefix}checkUpdates', checkUpdates);
    }
    notifyListeners();
  }
}
