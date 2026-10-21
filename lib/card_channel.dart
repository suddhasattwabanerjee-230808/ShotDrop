import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

enum CardAccess { ok, missing, noPermission }

/// The Android side of the SD card (CardChannel.kt). Flutter can't read
/// content:// uris itself, so everything it shows is a file this side writes.
class CardChannel {
  CardChannel._();
  static final instance = CardChannel._();

  static const _m = MethodChannel('shotdrop/card');
  static const _events = EventChannel('shotdrop/card/events');

  /// Fires whenever a storage volume is mounted or removed.
  Stream<void> get volumeChanges => _events.receiveBroadcastStream().map((_) {});

  /// Opens the system folder picker (on the plugged-in card's DCIM folder,
  /// if there is one). Returns the chosen folder (persisted), or null.
  Future<String?> pickFolder() => _m.invokeMethod<String>('pickFolder');

  /// A folder picked before (permission kept) that's readable right now:
  /// the card it's on is plugged in. DCIM folders on cards first.
  Future<String?> findCard() => _m.invokeMethod<String>('findCard');

  /// The name of a plugged-in removable card (e.g. "SanDisk USB drive"), or null.
  Future<String?> cardVolume() => _m.invokeMethod<String>('cardVolume');

  Future<CardAccess> access(String treeUri) async {
    final r = await _m.invokeMethod<String>('access', {'treeUri': treeUri});
    return CardAccess.values.asNameMap()[r] ?? CardAccess.missing;
  }

  Future<List<CardFile>> list(String treeUri) async {
    final r = await _m.invokeListMethod<Map<Object?, Object?>>('list', {'treeUri': treeUri});
    return [for (final m in r ?? const <Map<Object?, Object?>>[]) CardFile.fromMap(m)];
  }

  /// An upright JPEG of [file] at most [maxEdge] px, cached on the phone.
  /// [fast] reads only the camera's tiny built-in thumbnail (instant, blurry).
  Future<String?> thumbnail(CardFile file, {required int maxEdge, bool fast = false}) => _m.invokeMethod<String>(
    'thumbnail',
    {'uri': file.uri, 'key': '${file.docId}|${file.modified}|${file.size}', 'maxEdge': maxEdge, 'fast': fast},
  );

  /// Copies the card JPEG to [dest] as an upright JPEG, at most [maxEdge] px.
  Future<void> importSource(CardFile file, String dest, {int maxEdge = 4000}) =>
      _m.invokeMethod('importSource', {'uri': file.uri, 'dest': dest, 'maxEdge': maxEdge});

  /// Writes raw RGBA pixels to [dest] as a JPEG.
  Future<void> encodeJpeg(Uint8List rgba, int width, int height, String dest, {int quality = 92}) =>
      _m.invokeMethod('encodeJpeg', {'rgba': rgba, 'width': width, 'height': height, 'dest': dest, 'quality': quality});

  /// Puts a copy of [path] in the phone gallery under Pictures/[album]. Returns its uri.
  Future<String?> saveToGallery(String path, String name, {String album = 'ShotDrop/Upload'}) =>
      _m.invokeMethod<String>('saveToGallery', {'path': path, 'name': name, 'album': album});

  Future<void> deleteFromGallery(String uri) => _m.invokeMethod('deleteFromGallery', {'uri': uri});
}
