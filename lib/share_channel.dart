import 'package:flutter/services.dart';

enum SocialApp { instagram, facebook }

enum ShareKind { feed, story }

enum ShareOutcome { launched, chooser, noMultiple, notInstalled }

/// The Android side of posting (ShareChannel.kt): opens Instagram's or
/// Facebook's own composer with the photos loaded.
class ShareChannel {
  ShareChannel._();
  static final instance = ShareChannel._();

  static const _m = MethodChannel('shotdrop/share');

  Future<({bool instagram, bool facebook})> installedApps() async {
    final r = await _m.invokeMapMethod<String, bool>('apps') ?? const {};
    return (instagram: r['instagram'] ?? false, facebook: r['facebook'] ?? false);
  }

  Future<ShareOutcome> share(SocialApp app, ShareKind kind, List<String> paths) async {
    final r = await _m.invokeMethod<String>('share', {'app': app.name, 'kind': kind.name, 'paths': paths});
    return ShareOutcome.values.asNameMap()[r] ?? ShareOutcome.notInstalled;
  }

  /// Opens [url], in [app] when it's installed and handles the link.
  Future<bool> openUrl(String url, {SocialApp? app}) async =>
      await _m.invokeMethod<bool>('openUrl', {'url': url, 'app': app?.name}) ?? false;

  /// Moves a gallery copy (one ShotDrop made) to Pictures/[album].
  Future<void> moveInGallery(String uri, String album) =>
      _m.invokeMethod('moveInGallery', {'uri': uri, 'album': album});
}
