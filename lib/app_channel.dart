import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum InstallOutcome { started, needsPermission }

/// The app itself (AppChannel.kt): its version, installing an update, the
/// caption helper's switch in Accessibility settings, saved settings, and
/// storage.
class AppChannel {
  AppChannel._() {
    _m.setMethodCallHandler((call) async {
      if (call.method == 'cardPlugged') cardPlugged.value++;
    });
  }
  static final instance = AppChannel._();

  static const _m = MethodChannel('shotdrop/app');

  /// Goes up each time ShotDrop is opened by a card being plugged in.
  final cardPlugged = ValueNotifier<int>(0);

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

  /// Every saved setting, as Android has it.
  Future<Map<String, Object?>> prefs() async =>
      (await _m.invokeMapMethod<String, Object?>('prefs')) ?? <String, Object?>{};

  /// Saves one setting ([value] null removes it).
  Future<void> setPref(String key, Object? value) => _m.invokeMethod('setPref', {'key': key, 'value': value});

  /// Bytes free on the phone's storage.
  Future<int> freeSpace() async => await _m.invokeMethod<int>('freeSpace') ?? -1;

  /// Deletes ShotDrop's older error notes from Download; returns the bytes freed.
  Future<int> tidyNotes() async => await _m.invokeMethod<int>('tidyNotes') ?? 0;

  /// Notes an error in Download (ShotDrop-crash-…-dart.txt).
  Future<void> logError(String text) => _m.invokeMethod('logError', {'text': text});
}

final _reported = <String>{};

/// Notes [error] once per run (a repeating error doesn't fill Download).
void reportError(Object error, StackTrace? stack) {
  final text = 'Dart error: $error\n\n$stack';
  debugPrint(text);
  if (!_reported.add('$error')) return;
  AppChannel.instance.logError(text).catchError((Object _) {});
}
