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

  /// Opens [app]'s composer of [kind] with [paths]. A [caption] for an
  /// Instagram post is typed in by CaptionService, when it's switched on.
  Future<ShareOutcome> share(SocialApp app, ShareKind kind, List<String> paths, {String? caption}) async {
    final r = await _m.invokeMethod<String>('share', {
      'app': app.name,
      'kind': kind.name,
      'paths': paths,
      'caption': ?caption,
    });
    return ShareOutcome.values.asNameMap()[r] ?? ShareOutcome.notInstalled;
  }

  /// Android's share sheet with [paths] (WhatsApp, Bluetooth, Drive…). False if no app takes photos.
  Future<bool> shareAny(List<String> paths) async => await _m.invokeMethod<bool>('shareAny', {'paths': paths}) ?? false;

  /// Opens [url], in [app] when it's installed and handles the link.
  Future<bool> openUrl(String url, {SocialApp? app}) async =>
      await _m.invokeMethod<bool>('openUrl', {'url': url, 'app': app?.name}) ?? false;

  /// Moves a gallery copy (one ShotDrop made) to Pictures/[album].
  Future<void> moveInGallery(String uri, String album) =>
      _m.invokeMethod('moveInGallery', {'uri': uri, 'album': album});
}
