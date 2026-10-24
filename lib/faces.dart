import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app_channel.dart';
import 'models.dart';
import 'stores.dart' show ShotSource;
import 'turn.dart';

/// One face in a photo.
class Face {
  const Face({required this.crop, required this.box, this.embedding});

  final String crop; // a small square JPEG of the face, for the People sheet
  final Rect box; // 0..1 of the photo, as looked at (turned as shown, see turnOf)
  final Float32List? embedding; // 192 numbers, unit length; null when too small to tell who it is

  double get size => box.width * box.height;

  factory Face.fromMap(Map<Object?, Object?> m) {
    final b = [for (final v in m['box'] as List) (v as num).toDouble()];
    final e = m['embedding'];
    return Face(
      crop: m['crop'] as String,
      box: Rect.fromLTRB(b[0], b[1], b[2], b[3]),
      embedding: e is Uint8List ? _floats(e) : null,
    );
  }

  Map<String, Object?> toJson() => {
    'c': crop,
    'b': [box.left, box.top, box.right, box.bottom],
    if (embedding case final e?) 'e': base64Encode(_bytes(e)),
  };

  factory Face.fromJson(Map<String, Object?> j) {
    final b = [for (final v in j['b'] as List) (v as num).toDouble()];
    final e = j['e'] as String?;
    return Face(
      crop: j['c'] as String,
      box: Rect.fromLTRB(b[0], b[1], b[2], b[3]),
      embedding: e == null ? null : _floats(base64Decode(e)),
    );
  }
}

/// Little-endian float32s (the bytes may not start on a 4-byte boundary, so no view).
Float32List _floats(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return Float32List.fromList([for (var i = 0; i + 4 <= bytes.length; i += 4) data.getFloat32(i, Endian.little)]);
}

Uint8List _bytes(Float32List floats) {
  final data = ByteData(floats.length * 4);
  for (final (i, v) in floats.indexed) {
    data.setFloat32(i * 4, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// What a scan found in one photo.
class PhotoFaces {
  const PhotoFaces({this.faces = const []});

  final List<Face> faces;

  Map<String, Object?> toJson() => {
    if (faces.isNotEmpty) 'f': [for (final f in faces) f.toJson()],
  };

  factory PhotoFaces.fromJson(Map<String, Object?> j) => PhotoFaces(
    faces: [for (final f in (j['f'] as List?) ?? const []) Face.fromJson((f as Map).cast<String, Object?>())],
  );
}

/// One person: the faces that look alike, and the photos they're in.
class Person {
  const Person({required this.id, required this.cover, required this.faces, required this.photos});

  final String id; // the id of its biggest face ("<photo key>#<n>")
  final String cover; // that face's crop
  final Set<String> faces;
  final Set<String> photos; // FaceIndex.keyOf of each photo
}

/// The faces in every gallery photo, found on the phone (FaceChannel.kt),
/// card photos first, newest first, as soon as a gallery lists them: by the
/// time People is opened they're mostly there. Kept in faces.json, so each
/// photo is looked at once. Photos it couldn't look at are counted, and the
/// first reason of each kind is noted in Download (reportError).
class FaceIndex extends ChangeNotifier {
  FaceIndex._();
  static final instance = FaceIndex._();

  static const _m = MethodChannel('shotdrop/faces');

  /// Same person: how alike (cosine) a face must be to a person's average face.
  static const sameness = 0.6;

  /// faces.json's layout. 2: card photos looked at turned left, as they're now shown.
  static const _version = 2;

  /// A photo taking longer than this is given up on (for this session), so one can't hold up the rest.
  static const _scanLimit = Duration(seconds: 45);

  final _byKey = <String, PhotoFaces>{};
  final _failed = <String>{}; // tried this session and couldn't be read; tried again when the gallery changes
  final _scanning = <String, Future<void>>{};
  final _sources = <ShotSource>[];
  var _pending = Queue<CardFile>();
  bool _pumping = false;
  Timer? _kickSoon, _saveSoon, _clusterSoon;
  int _clusterRun = 0;
  int _looked = 0, _found = 0; // this session: photos looked at, faces found in them
  bool _noted = false;

  /// Everyone seen in at least two photos, most photos first.
  List<Person> people = const [];

  /// Why the last photo that couldn't be looked at couldn't be.
  String? lastError;

  static String keyOf(CardFile f) => '${f.docId}|${f.modified}|${f.size}';

  bool isScanned(CardFile f) => _byKey.containsKey(keyOf(f)) || _failed.contains(keyOf(f));

  /// Looking at photos right now.
  bool get busy => _pumping || (_kickSoon?.isActive ?? false);

  /// How many of [shots] are still to be looked at.
  int remaining(Iterable<CardShot> shots) => shots.where((s) => s.jpg != null && !isScanned(s.jpg!)).length;

  /// How many of [shots] couldn't be looked at this session.
  int failed(Iterable<CardShot> shots) => shots.where((s) => s.jpg != null && _failed.contains(keyOf(s.jpg!))).length;

  Person? person(String id) => people.where((p) => p.id == id || p.faces.contains(id)).firstOrNull;

  Future<File> get _file async => File('${(await getApplicationSupportDirectory()).path}/faces.json');

  Future<void> load() async {
    try {
      final f = await _file;
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      if (j['v'] != _version) return; // looked at the old way: every photo is looked at again
      (j['photos'] as Map).forEach(
        (k, v) => _byKey[k as String] = PhotoFaces.fromJson((v as Map).cast<String, Object?>()),
      );
      _recluster(soon: false);
    } catch (e) {
      debugPrint('Faces unreadable, starting again: $e');
    }
  }

  void _save() {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(seconds: 3), () async {
      try {
        final f = await _file;
        final tmp = File('${f.path}.part');
        await tmp.writeAsString(jsonEncode({'v': _version, 'photos': _byKey.map((k, v) => MapEntry(k, v.toJson()))}));
        await tmp.rename(f.path);
      } catch (e) {
        debugPrint('Couldn\'t save faces: $e');
      }
    });
  }

  /// Looks at [source]'s photos, and again whenever they change.
  void track(ShotSource source) {
    _sources.add(source);
    source.addListener(_kick);
    _kick();
  }

  // Lists what's still to look at, then starts on it a moment later, out of the way of the
  // thumbnails. It carries on while ShotDrop is in the background, for as long as Android lets it.
  void _kick() {
    _failed.clear();
    _pending = Queue.of([
      for (final s in _sources)
        for (final shot in s.shots)
          if (shot.jpg case final f? when !isScanned(f)) f,
    ]);
    _kickSoon?.cancel();
    _kickSoon = Timer(const Duration(seconds: 2), _pump);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        final f = _pending.removeFirst();
        if (isScanned(f)) continue;
        await _scan(f);
        notifyListeners();
      }
    } finally {
      _pumping = false;
      notifyListeners();
    }
  }

  Future<void> _scan(CardFile file) {
    final key = keyOf(file);
    return _scanning[key] ??= () async {
      try {
        final r = await _m
            .invokeMapMethod<String, Object?>('scan', {'uri': file.uri, 'key': key, 'turn': turnOf(file)})
            .timeout(_scanLimit);
        final found = PhotoFaces(
          faces: [for (final f in (r?['faces'] as List?) ?? const []) Face.fromMap(f as Map<Object?, Object?>)],
        );
        _byKey[key] = found;
        _looked++;
        _found += found.faces.length;
        if (r?['embedError'] case final String why) reportError('Faces: $why', null);
        if (found.faces.any((f) => f.embedding != null)) _recluster();
        _save();
        _checkIn();
      } catch (e, st) {
        _failed.add(key);
        lastError = e is PlatformException ? (e.message ?? e.code) : '$e';
        // Once per kind of failure (reportError skips repeats), so the reason can be read off the phone.
        reportError('Faces: couldn\'t look at a photo: ${e is PlatformException ? '${e.message}\n${e.details}' : e}', st);
      } finally {
        _scanning.remove(key);
      }
    }();
  }

  // A note in Download if photos are being read but no faces turn up, which
  // would mean the face finder isn't working rather than nobody's there.
  void _checkIn() {
    if (_noted || _looked < 40) return;
    _noted = true;
    if (_found == 0) reportError('Faces: looked at $_looked photos and found no faces in any', null);
  }

  // Grouping is redone on the side (a few thousand faces is a lot of sums), a little after the last new face.
  void _recluster({bool soon = true}) {
    _clusterSoon?.cancel();
    _clusterSoon = Timer(soon ? const Duration(seconds: 2) : Duration.zero, () async {
      final run = ++_clusterRun;
      final faces = [
        for (final MapEntry(:key, :value) in _byKey.entries)
          for (final (i, f) in value.faces.indexed)
            if (f.embedding case final e?) (id: '$key#$i', photo: key, crop: f.crop, size: f.size, e: e),
      ];
      try {
        final found = await Isolate.run(() => groupFaces(faces));
        if (run != _clusterRun) return;
        people = found;
        notifyListeners();
      } catch (e) {
        debugPrint('Couldn\'t group faces: $e');
      }
    });
  }
}

typedef FaceEntry = ({String id, String photo, String crop, double size, Float32List e});

/// Groups faces into people: biggest (clearest) faces first, each joins the
/// person whose average face it's most like (if alike enough) or starts a
/// new one; then people who turn out alike are joined. Only people in two
/// photos or more are kept.
List<Person> groupFaces(List<FaceEntry> faces, {double same = FaceIndex.sameness}) {
  final order = [...faces]..sort((a, b) => b.size.compareTo(a.size));
  var sums = <Float32List>[];
  var lengths = <double>[];
  var members = <List<FaceEntry>>[];

  double dot(Float32List a, Float32List b) {
    var d = 0.0;
    for (var i = 0; i < a.length; i++) {
      d += a[i] * b[i];
    }
    return d;
  }

  void add(int c, Float32List e) {
    final s = sums[c];
    for (var i = 0; i < s.length; i++) {
      s[i] += e[i];
    }
    lengths[c] = math.sqrt(dot(s, s));
  }

  for (final f in order) {
    var best = -1;
    var bestSim = same;
    for (var c = 0; c < sums.length; c++) {
      final sim = dot(sums[c], f.e) / lengths[c];
      if (sim >= bestSim) {
        bestSim = sim;
        best = c;
      }
    }
    if (best < 0) {
      sums.add(Float32List.fromList(f.e));
      lengths.add(math.sqrt(dot(f.e, f.e)));
      members.add([f]);
    } else {
      add(best, f.e);
      members[best].add(f);
    }
  }

  // Joins people whose average faces are alike (the first faces seen of someone can start two).
  for (var merged = true; merged;) {
    merged = false;
    final units = [
      for (final (c, s) in sums.indexed) Float32List.fromList([for (final v in s) v / lengths[c]]),
    ];
    final gone = <int>{};
    for (var a = 0; a < sums.length; a++) {
      if (gone.contains(a)) continue;
      for (var b = a + 1; b < sums.length; b++) {
        if (gone.contains(b) || dot(units[a], units[b]) < same + 0.05) continue;
        add(a, sums[b]);
        members[a].addAll(members[b]);
        gone.add(b);
        merged = true;
      }
    }
    bool kept(int c) => !gone.contains(c);
    sums = [
      for (final (c, s) in sums.indexed)
        if (kept(c)) s,
    ];
    lengths = [
      for (final (c, l) in lengths.indexed)
        if (kept(c)) l,
    ];
    members = [
      for (final (c, m) in members.indexed)
        if (kept(c)) m,
    ];
  }

  final people = [
    for (final m in members)
      if ({for (final f in m) f.photo}.length >= 2)
        Person(
          id: m.first.id,
          cover: m.first.crop,
          faces: {for (final f in m) f.id},
          photos: {for (final f in m) f.photo},
        ),
  ];
  people.sort((a, b) => b.photos.length.compareTo(a.photos.length));
  return people;
}
