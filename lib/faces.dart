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

import 'models.dart';
import 'stores.dart' show ShotSource;

/// One face in a photo.
class Face {
  const Face({required this.crop, required this.box, this.embedding});

  final String crop; // a small square JPEG of the face, for the People sheet
  final Rect box; // 0..1 of the photo, as turned upright
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

/// What a scan found in one photo: how to turn it upright, and its faces.
class PhotoFaces {
  const PhotoFaces({this.turn = 0, this.faces = const []});

  final int turn; // quarter turns clockwise: 3 = left 90°, for a person lying sideways
  final List<Face> faces;

  Map<String, Object?> toJson() => {
    if (turn != 0) 't': turn,
    if (faces.isNotEmpty) 'f': [for (final f in faces) f.toJson()],
  };

  factory PhotoFaces.fromJson(Map<String, Object?> j) => PhotoFaces(
    turn: (j['t'] as num?)?.toInt() ?? 0,
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
/// newest photos first, while ShotDrop is open. Kept in faces.json, so each
/// photo is looked at once. Also says which photos show a person lying
/// sideways, so the galleries, Selected and the editor turn them upright.
class FaceIndex extends ChangeNotifier {
  FaceIndex._();
  static final instance = FaceIndex._();

  static const _m = MethodChannel('shotdrop/faces');

  /// Same person: how alike (cosine) a face must be to a person's average face.
  static const sameness = 0.6;

  final _byKey = <String, PhotoFaces>{};
  final _failed = <String>{}; // tried this session and couldn't be read; tried again when the gallery changes
  final _scanning = <String, Future<void>>{};
  final _sources = <ShotSource>[];
  var _pending = Queue<CardFile>();
  bool _paused = false, _pumping = false;
  Timer? _kickSoon, _saveSoon, _clusterSoon;
  int _clusterRun = 0;

  /// Bumps when a photo is found to need turning: the tiles listen to this, not every scan.
  final turns = ValueNotifier<int>(0);

  /// Everyone seen in at least two photos, most photos first.
  List<Person> people = const [];

  static String keyOf(CardFile f) => '${f.docId}|${f.modified}|${f.size}';

  int turnOf(CardFile f) => _byKey[keyOf(f)]?.turn ?? 0;
  bool isScanned(CardFile f) => _byKey.containsKey(keyOf(f)) || _failed.contains(keyOf(f));

  /// How many of [shots] are still to be looked at.
  int remaining(Iterable<CardShot> shots) => shots.where((s) => s.jpg != null && !isScanned(s.jpg!)).length;

  Person? person(String id) => people.where((p) => p.id == id || p.faces.contains(id)).firstOrNull;

  Future<File> get _file async => File('${(await getApplicationSupportDirectory()).path}/faces.json');

  Future<void> load() async {
    try {
      final f = await _file;
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      (j['photos'] as Map).forEach(
        (k, v) => _byKey[k as String] = PhotoFaces.fromJson((v as Map).cast<String, Object?>()),
      );
      turns.value++;
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
        await tmp.writeAsString(jsonEncode({'v': 1, 'photos': _byKey.map((k, v) => MapEntry(k, v.toJson()))}));
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

  void pause() => _paused = true;

  void resume() {
    _paused = false;
    _kick();
  }

  // Lists what's still to look at, then starts on it a moment later, out of the way of the thumbnails.
  void _kick() {
    _failed.clear();
    _pending = Queue.of([
      for (final s in _sources)
        for (final shot in s.shots)
          if (shot.jpg case final f? when !isScanned(f)) f,
    ]);
    _kickSoon?.cancel();
    _kickSoon = Timer(const Duration(seconds: 3), _pump);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    var n = 0;
    try {
      while (!_paused && _pending.isNotEmpty) {
        final f = _pending.removeFirst();
        if (isScanned(f)) continue;
        await _scan(f);
        if (++n % 10 == 0) notifyListeners();
      }
    } finally {
      _pumping = false;
      if (n > 0) notifyListeners();
    }
  }

  /// [file]'s turn, looking at it now (ahead of the rest) if it hasn't been yet.
  Future<int> turnFor(CardFile file) async {
    if (!isScanned(file)) {
      try {
        await _scan(file).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Not upright-checked: it stays as the camera saved it.
      }
    }
    return turnOf(file);
  }

  Future<void> _scan(CardFile file) {
    final key = keyOf(file);
    return _scanning[key] ??= () async {
      try {
        final r = await _m.invokeMapMethod<String, Object?>('scan', {'uri': file.uri, 'key': key});
        final found = PhotoFaces(
          turn: (r?['turn'] as num?)?.toInt() ?? 0,
          faces: [for (final f in (r?['faces'] as List?) ?? const []) Face.fromMap(f as Map<Object?, Object?>)],
        );
        _byKey[key] = found;
        if (found.turn != 0) turns.value++;
        if (found.faces.any((f) => f.embedding != null)) _recluster();
        _save();
      } catch (e) {
        _failed.add(key);
      } finally {
        _scanning.remove(key);
      }
    }();
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

/// [child] (a photo of [file]) turned upright when FaceIndex found the person in it lying sideways.
class Upright extends StatelessWidget {
  const Upright({super.key, required this.file, required this.child});
  final CardFile file;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: FaceIndex.instance.turns,
    builder: (context, _, child) => RotatedBox(quarterTurns: FaceIndex.instance.turnOf(file), child: child),
    child: child,
  );
}
