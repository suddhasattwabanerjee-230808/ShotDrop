import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_channel.dart';
import 'stores.dart';
import 'update.dart';

/// Below this much free space on the phone, ShotDrop tidies harder.
const lowSpaceBytes = 1500 * 1000 * 1000;

/// Thumbnails of card photos are made again when needed, so they're kept to
/// this much (less when the phone is short of space), and none older than
/// [thumbMaxAge].
const thumbCapBytes = 200 * 1000 * 1000, thumbLowCapBytes = 40 * 1000 * 1000;
const thumbMaxAge = Duration(days: 30);

/// Keeps ShotDrop's space in check: copies nothing uses any more, copies of
/// posted photos after [AppSettings.keepPostedDays] (straight away when the
/// phone is low on space), old thumbnails, installed updates' APKs and old
/// error notes in Download. Never touches Selected or the Upload folder.
/// Returns the bytes freed.
Future<int> tidyStorage(UploadStore uploads, AppSettings settings) async {
  var freed = 0;
  Future<void> step(Future<int> Function() f) async {
    try {
      freed += await f();
    } catch (_) {
      // One part failing (a file in use, storage unreadable) doesn't stop the rest.
    }
  }

  final free = await AppChannel.instance.freeSpace().catchError((Object _) => -1);
  final low = free >= 0 && free < lowSpaceBytes;
  await step(uploads.clearUnused);
  if (low) {
    await step(uploads.clearPosted);
  } else if (settings.keepPostedDays > 0) {
    await step(() => uploads.clearPosted(before: DateTime.now().subtract(Duration(days: settings.keepPostedDays))));
  }
  final cache = await getTemporaryDirectory();
  await step(() => trimThumbs(Directory('${cache.path}/thumbs'), low ? thumbLowCapBytes : thumbCapBytes));
  await step(() => clearOldUpdates(Directory('${cache.path}/updates')));
  await step(() => AppChannel.instance.tidyNotes());
  return freed;
}

/// Deletes every thumbnail, photo copied ahead and downloaded update (all
/// made again when needed), but not [keep]: an update the installer has open.
/// Done each time ShotDrop goes to the background. Returns the bytes freed.
Future<int> clearCacheFiles({String? keep}) async {
  final cache = await getTemporaryDirectory();
  var freed = 0;
  for (final name in ['thumbs', 'sources', 'updates']) {
    final dir = Directory('${cache.path}/$name');
    if (!await dir.exists()) continue;
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path != keep) freed += await UploadStore.deleteFile(e);
    }
  }
  return freed;
}

/// Deletes thumbnails older than [thumbMaxAge], then the least recently used
/// until the rest fit in [cap] bytes.
Future<int> trimThumbs(Directory dir, int cap, {DateTime? now}) async {
  if (!await dir.exists()) return 0;
  final cutoff = (now ?? DateTime.now()).subtract(thumbMaxAge);
  final files = <(File, DateTime, int)>[];
  var freed = 0, total = 0;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    final stat = await e.stat();
    if (stat.modified.isBefore(cutoff)) {
      freed += await UploadStore.deleteFile(e);
    } else {
      files.add((e, stat.modified, stat.size));
      total += stat.size;
    }
  }
  files.sort((a, b) => a.$2.compareTo(b.$2)); // oldest first (opening one marks it used)
  for (final (f, _, size) in files) {
    if (total <= cap) break;
    total -= size;
    freed += await UploadStore.deleteFile(f);
  }
  return freed;
}

/// Deletes downloaded updates for this version or older (installed, or passed over).
Future<int> clearOldUpdates(Directory dir) async {
  if (!await dir.exists()) return 0;
  final current = (await AppChannel.instance.version()).name;
  var freed = 0;
  await for (final e in dir.list(followLinks: false)) {
    final v = RegExp(r'ShotDrop-(.+)\.apk(\.part)?$').firstMatch(e.path)?.group(1);
    if (e is File && v != null && compareVersions(v, current) <= 0) freed += await UploadStore.deleteFile(e);
  }
  return freed;
}
