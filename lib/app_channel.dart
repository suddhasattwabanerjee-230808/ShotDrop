import 'package:flutter/services.dart';

enum InstallOutcome { started, needsPermission }

/// The app itself (AppChannel.kt): its version, installing an update, and
/// the caption helper's switch in Accessibility settings.
class AppChannel {
  AppChannel._();
  static final instance = AppChannel._();

  static const _m = MethodChannel('shotdrop/app');

  Future<({String name, int code})> version() async {
    final r = await _m.invokeMapMethod<String, Object?>('version') ?? const {};
    return (name: r['name'] as String? ?? '0.0.0', code: (r['code'] as num?)?.toInt() ?? 0);
  }

  /// Opens Android's installer on the APK at [path]. needsPermission: Settings
  /// was opened on "Install unknown apps" for ShotDrop; allow it, then try again.
  Future<InstallOutcome> install(String path) async {
    final r = await _m.invokeMethod<String>('install', {'path': path});
    return r == 'started' ? InstallOutcome.started : InstallOutcome.needsPermission;
  }

  /// Whether "ShotDrop caption paste" is on in Accessibility settings.
  Future<bool> captionHelperOn() async => await _m.invokeMethod<bool>('captionHelperOn') ?? false;

  Future<void> openAccessibility() => _m.invokeMethod('openAccessibility');

  /// App info, where Android hides "Allow restricted settings" for apps not from the Play Store.
  Future<void> openAppInfo() => _m.invokeMethod('openAppInfo');
}
