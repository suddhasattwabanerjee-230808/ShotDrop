import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_channel.dart';

/// Where new versions are published: a public repo that holds only the APKs
/// (the source repo is private), filled by the release workflow.
const releasesRepo = 'suddhasattwabanerjee-230808/ShotDrop-releases';

/// A published version of the app.
class Release {
  const Release({required this.version, required this.notes, required this.apkUrl, required this.apkSize});
  final String version; // "0.5.0"
  final String notes; // the changelog section
  final String apkUrl;
  final int apkSize;
}

/// -1, 0 or 1 as version [a] is older than, the same as or newer than [b] ("1.2.3", "v1.2" …).
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+]')).take(3)) int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// Checks for, downloads and installs new versions. One per app; screens
/// listen to it for the "update available" dot and the download's progress.
class Updater extends ChangeNotifier {
  Updater({HttpClient Function()? client}) : _client = client ?? HttpClient.new;
  final HttpClient Function() _client;

  String current = '';
  Release? latest; // set when it's newer than [current]
  bool checking = false;
  String? error;
  double? progress; // 0..1 while downloading

  bool get available => latest != null;

  /// Looks for a newer version. Quietly does nothing offline.
  Future<void> check() async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      current = (await AppChannel.instance.version()).name;
      final client = _client()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$releasesRepo/releases/latest'));
        req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
        final res = await req.close();
        if (res.statusCode == 404) {
          latest = null; // nothing published there yet
        } else if (res.statusCode != 200) {
          throw 'GitHub answered ${res.statusCode}';
        } else {
          latest = parseRelease(await res.transform(utf8.decoder).join(), current);
        }
      } finally {
        client.close();
      }
    } catch (e) {
      error = '$e';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// The release in GitHub's JSON [body] if it's newer than [current] and has an APK.
  @visibleForTesting
  static Release? parseRelease(String body, String current) {
    final j = jsonDecode(body) as Map<String, Object?>;
    final tag = j['tag_name'] as String? ?? '';
    if (compareVersions(tag, current) <= 0) return null;
    for (final a in (j['assets'] as List? ?? const []).cast<Map<String, Object?>>()) {
      final name = a['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        return Release(
          version: tag.replaceFirst(RegExp(r'^v'), ''),
          notes: (j['body'] as String? ?? '').trim(),
          apkUrl: a['browser_download_url'] as String,
          apkSize: (a['size'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return null;
  }

  /// Downloads [latest] and opens Android's installer on it.
  Future<InstallOutcome> install() async {
    final r = latest!;
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    final file = File('${dir.path}/ShotDrop-${r.version}.apk');
    if (!(await file.exists() && await file.length() == r.apkSize && r.apkSize > 0)) {
      progress = 0;
      notifyListeners();
      final client = _client();
      try {
        final res = await (await client.getUrl(Uri.parse(r.apkUrl))).close(); // follows GitHub's redirect
        if (res.statusCode != 200) throw 'Download failed (${res.statusCode})';
        final total = res.contentLength > 0 ? res.contentLength : r.apkSize;
        final part = File('${file.path}.part');
        final sink = part.openWrite();
        var got = 0;
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
        await sink.close();
        await part.rename(file.path);
      } finally {
        client.close();
        progress = null;
        notifyListeners();
      }
    }
    return AppChannel.instance.install(file.path);
  }
}
