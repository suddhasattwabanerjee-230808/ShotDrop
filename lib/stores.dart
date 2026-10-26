import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_channel.dart';
import 'card_channel.dart';
import 'models.dart';
import 'prefetch.dart';
import 'publish.dart';
import 'share_channel.dart';
import 'turn.dart';

/// The app's saved settings, kept by Android (AppChannel, its own
/// SharedPreferences file). Not the shared_preferences plugin: in release
/// builds it saved nothing, and 0.5.2 waited on it forever at a black
/// screen. Read once; a failed read gives empty settings, never a hang.
class Prefs {
  Prefs._(this._values);
  final Map<String, Object?> _values;

  static Future<Prefs>? _loaded;
  static Future<Prefs> load() => _loaded ??= AppChannel.instance
      .prefs()
      .timeout(const Duration(seconds: 3))
      .then(Prefs._, onError: (Object e, StackTrace st) {
        reportError('Couldn\'t read the settings: $e', st);
        return Prefs._({});
      });

  String? getString(String key) => _values[key] as String?;
  bool? getBool(String key) => _values[key] as bool?;
  int? getInt(String key) => (_values[key] as num?)?.toInt();

  Future<void> setString(String key, String value) => _set(key, value);
  Future<void> setBool(String key, bool value) => _set(key, value);
  Future<void> setInt(String key, int value) => _set(key, value);

  Future<void> _set(String key, Object value) async {
    _values[key] = value;
    await AppChannel.instance.setPref(key, value).catchError((Object e, StackTrace st) {
      reportError('Couldn\'t save "$key": $e', st);
    });
  }
}

Future<Prefs> prefs() => Prefs.load();

enum CardState { noFolder, waiting, newCard, loading, ready, error }

/// Where a gallery grid's photos come from: the camera card or the phone.
abstract class ShotSource implements Listenable {
  List<CardShot> get shots;
  Future<void> refresh();
}

/// The camera card: which folder was picked, whether it's plugged in, and the
/// shots on it. Rescans by itself when a card is plugged in or pulled out
/// (and every few seconds while waiting for one, in case the phone doesn't
/// say). A card picked before opens by itself; a new one asks once, with the
/// picker already on its DCIM folder.
class CardStore extends ChangeNotifier implements ShotSource {
  CardStore({CardChannel? channel}) : _channel = channel ?? CardChannel.instance;

  final CardChannel _channel;
  static const _folderKey = 'shotdrop.card_folder.v1';

  String? folder;
  CardState state = CardState.noFolder;
  @override
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

  @override
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

enum PhoneState { unknown, noAccess, blocked, loading, ready, error }

/// The Phone Gallery: every photo in the phone's own gallery, newest first.
/// Nothing is read (and Android doesn't ask for access) until it's opened.
class PhoneStore extends ChangeNotifier implements ShotSource {
  PhoneStore({CardChannel? channel}) : _channel = channel ?? CardChannel.instance;

  final CardChannel _channel;
  PhoneState state = PhoneState.unknown;
  bool partial = false; // only the photos picked in Android's "Select photos"
  String? error;
  @override
  List<CardShot> shots = const [];
  bool _refreshing = false;

  /// Lists the photos again, if ShotDrop may see them.
  @override
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final access = await _channel.phoneAccess();
      await _show(access);
    } catch (e) {
      error = '$e';
      _set(PhoneState.error);
    } finally {
      _refreshing = false;
    }
  }

  /// Asks Android for the photos, then shows them.
  Future<void> requestAccess() async {
    try {
      await _show(await _channel.requestPhoneAccess());
    } catch (e) {
      error = '$e';
      _set(PhoneState.error);
    }
  }

  Future<void> _show(PhotoAccess access) async {
    partial = access == PhotoAccess.partial;
    if (access == PhotoAccess.none || access == PhotoAccess.blocked) {
      shots = const [];
      _set(access == PhotoAccess.blocked ? PhoneState.blocked : PhoneState.noAccess);
      return;
    }
    if (state != PhoneState.ready) _set(PhoneState.loading);
    final files = await _channel.phoneList();
    shots = [for (final f in files) CardShot(key: f.docId.toUpperCase(), jpg: f)];
    _set(PhoneState.ready);
  }

  void _set(PhoneState s) {
    state = s;
    notifyListeners();
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
  PublishSession? session; // a round of publishing still waiting on "Did It Post?"
  bool _editedSelectedCorrectionDone = false;

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
  List<UploadItem> get storyLater => _with(ItemStatus.storyLater);

  /// Selected, most recently added first.
  List<UploadItem> get selected => _with(ItemStatus.selected).reversed.toList();

  bool contains(String shotId) => items.any((i) => (i.shotId == shotId || i.originShotId == shotId) && i.status == ItemStatus.queued);
  bool isSelected(String shotId) => items.any((i) => i.shotId == shotId && i.status == ItemStatus.selected);
  bool isPublished(String shotId) => items.any((i) => (i.shotId == shotId || i.originShotId == shotId) && i.published);
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
      final sj = j['session'];
      session = sj is Map ? PublishSession.fromJson(sj.cast<String, Object?>(), byShot) : null;
      _editedSelectedCorrectionDone = j['editedSelectedCorrectionDone'] == true;
      await _correctEditedSelectedOnce();
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
        'session': ?session?.toJson(),
        'editedSelectedCorrectionDone': _editedSelectedCorrectionDone,
      }),
    );
    await tmp.rename(f.path);
  }

  /// One-time repair: retain each edited Selected item and add its edited copy
  /// to Uploads, sharing the kept files until either item no longer needs them.
  Future<void> _correctEditedSelectedOnce() async {
    if (_editedSelectedCorrectionDone) return;
    final edited = [for (final item in items) if (item.status == ItemStatus.selected && item.edited) item];
    for (final item in edited) {
      final copyId = '${item.shotId}_edited_upload';
      if (items.any((i) => i.shotId == copyId)) continue;
      items = [
        ...items,
        UploadItem(
          shotId: copyId,
          originShotId: item.originShotId ?? item.shotId,
          name: item.name,
          taken: item.taken,
          sourcePath: item.sourcePath,
          exportPath: item.exportPath,
          params: item.params,
          status: ItemStatus.queued,
          width: item.width,
          height: item.height,
        ),
      ];
    }
    _editedSelectedCorrectionDone = true;
    await _save();
  }

  bool _fileUsedElsewhere(String path, String shotId) => items.any(
    (i) => i.shotId != shotId && (i.sourcePath == path || i.exportPath == path),
  );

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
          if (!await SourcePrefetch.take(s.jpg!, path)) {
            await _card.importSource(s.jpg!, path, turn: turnOf(s.jpg!));
          }
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
      // Edited out of Selected: it joins the end of the posting order.
      items = old.status == item.status ? ([...items]..[i] = item) : [...items..removeAt(i), item];
      if (oldExport != null && oldExport != item.exportPath && !_fileUsedElsewhere(oldExport, item.shotId)) {
        _deleteQuietly(oldExport);
      }
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
    if (export != null && !_fileUsedElsewhere(export, item.shotId)) _deleteQuietly(export);
    if (!_fileUsedElsewhere(item.sourcePath, item.shotId)) _deleteQuietly(item.sourcePath);
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

  /// Starts (or with null, forgets) a round of publishing, saved so it's
  /// still there if ShotDrop is closed while Instagram is open.
  Future<void> setSession(PublishSession? s) async {
    session = s;
    notifyListeners();
    await _save();
  }

  /// After a round of publishing: [posted] photos are marked posted (the grid
  /// shows POSTED; their gallery copies stay in Pictures/ShotDrop).
  /// Photos left for [later] and photos not included in this round stay in the
  /// Upload folder. Nothing moves if nothing was posted.
  Future<void> finishPublishing(Iterable<String> posted, {Iterable<String> later = const [], bool keepStoriesForPosts = false}) async {
    final ids = posted.toSet();
    session = null;
    if (ids.isNotEmpty) {
      final now = DateTime.now();
      items = [
        for (final i in items)
          ids.contains(i.shotId)
              ? i.copyWith(status: keepStoriesForPosts ? ItemStatus.storyLater : ItemStatus.published, postedAt: now)
              : i,
      ];
      if (queued.isEmpty) caption = '';
    }
    notifyListeners();
    await _save();
    for (final i in items) {
      final g = i.galleryUri;
      if (ids.contains(i.shotId) && i.status == ItemStatus.published && g != null) {
        ShareChannel.instance.moveInGallery(g, 'ShotDrop').catchError((Object _) {});
      }
    }
  }

  /// Deletes the copies kept for posted photos (they stay marked POSTED);
  /// with [before], only of photos posted before then. Returns the bytes freed.
  Future<int> clearPosted({DateTime? before}) async {
    var freed = 0;
    for (final i in items) {
      if (!i.published) continue;
      final files = [File(i.sourcePath), if (i.exportPath case final e?) File(e)];
      if (before != null) {
        // Posted before 0.6.0 (no date kept): when its newest copy was made.
        var at = i.postedAt;
        if (at == null) {
          for (final f in files) {
            final m = await f.lastModified().then<DateTime?>((m) => m, onError: (Object _) => null);
            if (m != null && (at == null || m.isAfter(at))) at = m;
          }
        }
        if (at == null || at.isAfter(before)) continue;
      }
      for (final f in files) {
        if (!_fileUsedElsewhere(f.path, i.shotId)) freed += await deleteFile(f);
      }
    }
    return freed;
  }

  /// Deletes files in the Upload folder's storage that nothing uses any more:
  /// copies of photos that are gone, and the story and reshaped copies made
  /// for publishing once it's over. Leaves anything made in the last hour
  /// (an edit being saved). Returns the bytes freed.
  Future<int> clearUnused() async {
    final used = {
      for (final i in items) ...[i.sourcePath, ?i.exportPath],
    };
    // While publishing, the copies made for it are still needed.
    final stems = [
      for (final step in session?.steps ?? const <PublishStep>[])
        for (final i in step.items) i.previewPath.replaceFirst(RegExp(r'\.jpg$'), '-'),
    ];
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    var freed = 0;
    for (final sub in ['sources', 'uploads']) {
      final d = Directory('${(await dir).path}/$sub');
      if (!await d.exists()) continue;
      await for (final e in d.list(followLinks: false)) {
        if (e is! File || used.contains(e.path) || stems.any(e.path.startsWith)) continue;
        final m = await e.lastModified().then<DateTime?>((m) => m, onError: (Object _) => null);
        if (m == null || m.isAfter(cutoff)) continue;
        freed += await deleteFile(e);
      }
    }
    return freed;
  }

  Future<void> setCaption(String text) async {
    caption = text;
    await _save();
  }

  /// Deletes [f] if it's there; returns its size.
  static Future<int> deleteFile(File f) async {
    try {
      final n = await f.length();
      await f.delete();
      return n;
    } catch (_) {
      return 0;
    }
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
  bool galleryCopy = false; // optionally put edits in Pictures/ShotDrop
  String publishMode = 'post'; // a PublishMode name: what the Publish sheet starts on
  String postFit = 'crop'; // a PostFit name: how photos that don't fit a post are reshaped
  bool checkUpdates = true; // look for a new version at launch
  bool openOnCard = true; // open ShotDrop when a card is plugged in
  bool autoTidy = true; // clear what ShotDrop no longer needs, at launch and after publishing
  int keepPostedDays = 7; // how long copies of posted photos stay (0 = until cleared by hand)
  bool lightMode = false; // light colours instead of the camera-screen dark

  Future<void> load() async {
    final p = await prefs();
    portraitAt45 = p.getBool('${_prefix}portraitAt45') ?? portraitAt45;
    saveEdge = p.getInt('${_prefix}saveEdge') ?? saveEdge;
    galleryCopy = p.getBool('${_prefix}galleryCopy') ?? galleryCopy;
    publishMode = p.getString('${_prefix}publishMode') ?? publishMode;
    postFit = p.getString('${_prefix}postFit') ?? postFit;
    checkUpdates = p.getBool('${_prefix}checkUpdates') ?? checkUpdates;
    openOnCard = p.getBool('${_prefix}openOnCard') ?? openOnCard;
    autoTidy = p.getBool('${_prefix}autoTidy') ?? autoTidy;
    keepPostedDays = p.getInt('${_prefix}keepPostedDays') ?? keepPostedDays;
    lightMode = p.getBool('${_prefix}lightMode') ?? lightMode;
    notifyListeners();
  }

  Future<void> set({
    bool? portraitAt45,
    int? saveEdge,
    bool? galleryCopy,
    String? publishMode,
    String? postFit,
    bool? checkUpdates,
    bool? openOnCard,
    bool? autoTidy,
    int? keepPostedDays,
    bool? lightMode,
  }) async {
    final p = await prefs();
    Future<void> put(String key, Object? v) async {
      switch (v) {
        case bool b:
          await p.setBool('$_prefix$key', b);
        case int i:
          await p.setInt('$_prefix$key', i);
        case String s:
          await p.setString('$_prefix$key', s);
      }
    }

    this.portraitAt45 = portraitAt45 ?? this.portraitAt45;
    this.saveEdge = saveEdge ?? this.saveEdge;
    this.galleryCopy = galleryCopy ?? this.galleryCopy;
    this.publishMode = publishMode ?? this.publishMode;
    this.postFit = postFit ?? this.postFit;
    this.checkUpdates = checkUpdates ?? this.checkUpdates;
    this.openOnCard = openOnCard ?? this.openOnCard;
    this.autoTidy = autoTidy ?? this.autoTidy;
    this.keepPostedDays = keepPostedDays ?? this.keepPostedDays;
    this.lightMode = lightMode ?? this.lightMode;
    notifyListeners();
    await put('portraitAt45', portraitAt45);
    await put('saveEdge', saveEdge);
    await put('galleryCopy', galleryCopy);
    await put('publishMode', publishMode);
    await put('postFit', postFit);
    await put('checkUpdates', checkUpdates);
    await put('openOnCard', openOnCard);
    await put('autoTidy', autoTidy);
    await put('keepPostedDays', keepPostedDays);
    await put('lightMode', lightMode);
  }
}
