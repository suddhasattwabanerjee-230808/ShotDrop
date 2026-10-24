import 'dart:ui' show Rect;

import 'edit/body.dart';
import 'edit/shape.dart';

/// One file on the camera card, as the Android folder picker reports it.
class CardFile {
  const CardFile({
    required this.uri,
    required this.docId,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String uri; // content:// document uri, readable through the card channel
  final String docId; // e.g. "1A2B-3C4D:DCIM/100D5600/DSC_0123.JPG"
  final String name;
  final int size;
  final int modified; // ms since epoch; the camera writes the capture time here

  factory CardFile.fromMap(Map<Object?, Object?> m) => CardFile(
    uri: m['uri'] as String,
    docId: m['docId'] as String,
    name: m['name'] as String,
    size: (m['size'] as num?)?.toInt() ?? 0,
    modified: (m['modified'] as num?)?.toInt() ?? 0,
  );

  /// From the phone's own gallery (PhoneStore), not the card.
  bool get onPhone => docId.startsWith('phone:');

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
  }
}

/// One press of the shutter: the JPEG and/or the NEF the D5600 wrote for it.
class CardShot {
  const CardShot({required this.key, this.jpg, this.nef});

  /// Folder + file name without extension, upper-cased, e.g. "1A2B-3C4D:DCIM/100D5600/DSC_0123".
  final String key;
  final CardFile? jpg;
  final CardFile? nef;

  CardFile get primary => jpg ?? nef!;
  String get name => primary.name.substring(0, primary.name.lastIndexOf('.').clamp(0, primary.name.length));
  DateTime get taken => DateTime.fromMillisecondsSinceEpoch(primary.modified);
  bool get hasRaw => nef != null;
  bool get editable => jpg != null;

  /// Stable across rescans of the same card (the camera reuses names once it
  /// wraps past DSC_9999, so the capture time is part of it).
  String get id => '$key@${primary.modified}';
}

const _jpegExt = {'JPG', 'JPEG'};
const _rawExt = {'NEF', 'NRW'};

/// Groups card files into shots (a JPG and NEF with the same name in the same
/// folder are one shot), newest first. Anything that isn't a photo is dropped.
List<CardShot> pairShots(Iterable<CardFile> files) {
  final jpgs = <String, CardFile>{};
  final nefs = <String, CardFile>{};
  for (final f in files) {
    final ext = f.extension;
    final dot = f.docId.lastIndexOf('.');
    if (dot < 0) continue;
    final key = f.docId.substring(0, dot).toUpperCase();
    if (_jpegExt.contains(ext)) {
      jpgs[key] = f;
    } else if (_rawExt.contains(ext)) {
      nefs[key] = f;
    }
  }
  final shots = [
    for (final key in {...jpgs.keys, ...nefs.keys}) CardShot(key: key, jpg: jpgs[key], nef: nefs[key]),
  ];
  shots.sort((a, b) {
    final byTime = b.primary.modified.compareTo(a.primary.modified);
    return byTime != 0 ? byTime : b.key.compareTo(a.key);
  });
  return shots;
}

/// Crop frame presets. Instagram feed posts must sit between 4:5 and 1.91:1.
enum AspectPreset {
  free('Free', null),
  portrait('4:5', 4 / 5),
  square('1:1', 1),
  landscape('1.91:1', 1.91),
  story('9:16', 9 / 16),
  original('Original', null);

  const AspectPreset(this.label, this.ratio);
  final String label;
  final double? ratio; // width / height; null = not fixed (original uses the photo's own)
}

/// Everything the editor changed, kept so a photo can be re-edited from the
/// untouched source rather than from its own export.
class EditParams {
  const EditParams({
    this.quarterTurns = 0,
    this.flipH = false,
    this.straighten = 0,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.aspect = AspectPreset.original,
    this.height = 0,
    this.heightBand = const (0.45, 0.9),
    this.slims = const [],
    this.hips = 0,
    this.legs = 0,
    this.body,
    this.filter = 'original',
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
  });

  final int quarterTurns; // 0..3, clockwise
  final bool flipH;
  final double straighten; // degrees, -45..45
  final Rect crop; // normalized, in the rotated + straightened photo
  final AspectPreset aspect;

  /// Body tools. Stretch: [height] > 0 makes [heightBand] (top..bottom, 0..1
  /// of the cropped photo) longer, < 0 shorter, and the rest of the photo
  /// gives or takes the space, so the frame (and the shape picked for
  /// Instagram) stays the same.
  /// Slim: each of [slims] is one line-and-brackets area, applied in turn
  /// (see edit/shape.dart).
  /// Hip / Legs: [hips], [legs] are slider values 0..1, acting on the areas
  /// in [body] (null = BodyAnchors.defaults).
  final double height;
  final (double, double) heightBand;
  final List<SlimArea> slims;
  final double hips, legs;
  final BodyAnchors? body;

  BodyAnchors get bodyOrDefault => body ?? BodyAnchors.defaults;

  final String filter; // a FilterPreset id
  final double brightness, contrast, saturation, warmth; // each -1..1

  bool get isOriented => quarterTurns.isOdd;

  EditParams copyWith({
    int? quarterTurns,
    bool? flipH,
    double? straighten,
    Rect? crop,
    AspectPreset? aspect,
    double? height,
    (double, double)? heightBand,
    List<SlimArea>? slims,
    double? hips,
    double? legs,
    BodyAnchors? body,
    String? filter,
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
  }) => EditParams(
    quarterTurns: quarterTurns ?? this.quarterTurns,
    flipH: flipH ?? this.flipH,
    straighten: straighten ?? this.straighten,
    crop: crop ?? this.crop,
    aspect: aspect ?? this.aspect,
    height: height ?? this.height,
    heightBand: heightBand ?? this.heightBand,
    slims: slims ?? this.slims,
    hips: hips ?? this.hips,
    legs: legs ?? this.legs,
    body: body ?? this.body,
    filter: filter ?? this.filter,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    warmth: warmth ?? this.warmth,
  );

  Map<String, Object?> toJson() => {
    'quarterTurns': quarterTurns,
    'flipH': flipH,
    'straighten': straighten,
    'crop': [crop.left, crop.top, crop.right, crop.bottom],
    'aspect': aspect.name,
    'height': height,
    'heightBand': [heightBand.$1, heightBand.$2],
    if (slims.isNotEmpty) 'slims': [for (final s in slims) s.toJson()],
    'hips': hips,
    'legs': legs,
    if (body != null) 'body': body!.toJson(),
    'filter': filter,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'warmth': warmth,
  };

  factory EditParams.fromJson(Map<String, Object?> j) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    List<double> list(String k) => [for (final v in (j[k] as List? ?? const [])) (v as num).toDouble()];
    final c = list('crop');
    final hb = list('heightBand');
    final body = BodyAnchors.fromJson(j['body']);
    // 0.3.0's Slim drew the waist area in (0..1); it carries over as a Slim line across the waist.
    final oldSlim = d('slim');
    final waist = (body ?? BodyAnchors.defaults).waist;
    return EditParams(
      quarterTurns: (j['quarterTurns'] as num?)?.toInt() ?? 0,
      flipH: j['flipH'] == true,
      straighten: d('straighten'),
      crop: c.length == 4 ? Rect.fromLTRB(c[0], c[1], c[2], c[3]) : const Rect.fromLTWH(0, 0, 1, 1),
      aspect: AspectPreset.values.asNameMap()[j['aspect']] ?? AspectPreset.original,
      height: d('height'),
      heightBand: hb.length == 2 ? (hb[0], hb[1]) : const (0.45, 0.9),
      slims: [
        for (final s in (j['slims'] as List? ?? const [])) ?SlimArea.fromJson(s),
        if (oldSlim > 0 && j['slims'] == null) SlimArea(waist.cy, waist.cx - waist.rx * 0.6, waist.cx + waist.rx * 0.6, oldSlim),
      ],
      hips: d('hips'),
      legs: d('legs'),
      body: body,
      filter: j['filter'] as String? ?? 'original',
      brightness: d('brightness'),
      contrast: d('contrast'),
      saturation: d('saturation'),
      warmth: d('warmth'),
    );
  }
}

/// A photo sitting in the Upload folder, edited and waiting to be posted.
/// Where a photo kept by ShotDrop is: in Selected (picked from the card,
/// or set aside from the Upload folder for later), in the Upload folder
/// (edited, going out next), or posted.
enum ItemStatus { selected, queued, published }

/// A photo ShotDrop keeps: its own copy of the card JPEG, and once edited,
/// the edit and the export that gets posted.
class UploadItem {
  const UploadItem({
    required this.shotId,
    required this.name,
    required this.taken,
    required this.sourcePath,
    this.exportPath,
    this.params = const EditParams(),
    this.galleryUri,
    this.status = ItemStatus.queued,
    this.width,
    this.height,
    this.postedAt,
  });

  final String shotId; // CardShot.id, so the grid can mark it
  final String name; // DSC_0123
  final DateTime taken;
  final String sourcePath; // upright, untouched copy of the card JPEG
  final String? exportPath; // the edited JPEG that gets posted; null until it's edited
  final EditParams params;
  final String? galleryUri; // its copy in Pictures/ShotDrop/Upload
  final ItemStatus status;
  final int? width, height; // of the export, in pixels
  final DateTime? postedAt; // when it went out (its copies are tidied away some days later)

  bool get published => status == ItemStatus.published;
  bool get edited => exportPath != null;

  /// What to show for it: the edit if there is one, else the original.
  String get previewPath => exportPath ?? sourcePath;

  /// Width / height of the export, if known.
  double? get aspect => width != null && height != null && height! > 0 ? width! / height! : null;

  UploadItem copyWith({
    String? exportPath,
    EditParams? params,
    String? galleryUri,
    ItemStatus? status,
    DateTime? postedAt,
  }) => UploadItem(
    shotId: shotId,
    name: name,
    taken: taken,
    sourcePath: sourcePath,
    exportPath: exportPath ?? this.exportPath,
    params: params ?? this.params,
    galleryUri: galleryUri ?? this.galleryUri,
    status: status ?? this.status,
    width: width,
    height: height,
    postedAt: postedAt ?? this.postedAt,
  );

  Map<String, Object?> toJson() => {
    'shotId': shotId,
    'name': name,
    'taken': taken.millisecondsSinceEpoch,
    'sourcePath': sourcePath,
    'exportPath': exportPath,
    'params': params.toJson(),
    'galleryUri': galleryUri,
    'status': status.name,
    'width': width,
    'height': height,
    'postedAt': postedAt?.millisecondsSinceEpoch,
  };

  factory UploadItem.fromJson(Map<String, Object?> j) => UploadItem(
    shotId: j['shotId'] as String,
    name: j['name'] as String,
    taken: DateTime.fromMillisecondsSinceEpoch((j['taken'] as num).toInt()),
    sourcePath: j['sourcePath'] as String,
    exportPath: j['exportPath'] as String?,
    params: EditParams.fromJson((j['params'] as Map).cast<String, Object?>()),
    galleryUri: j['galleryUri'] as String?,
    // Before 0.5.0 there was only "published" (everything else was in the Upload folder).
    status:
        ItemStatus.values.asNameMap()[j['status']] ??
        (j['published'] == true ? ItemStatus.published : ItemStatus.queued),
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    postedAt: switch (j['postedAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
  );
}

/// [next] with the body tools (Slim's areas, Stretch's band, the body found)
/// moved so they stay on the same part of the photo when only the crop
/// changed since [prev]. They're kept relative to the crop, so without this a
/// re-crop would slide them onto something else.
EditParams followCrop(EditParams prev, EditParams next) {
  final a = prev.crop, b = next.crop;
  if (a == b ||
      prev.quarterTurns != next.quarterTurns ||
      prev.flipH != next.flipH ||
      prev.straighten != next.straighten ||
      b.width <= 0 ||
      b.height <= 0) {
    return next;
  }
  double x(double v) => (a.left + v * a.width - b.left) / b.width;
  double y(double v) => (a.top + v * a.height - b.top) / b.height;
  final sx = a.width / b.width, sy = a.height / b.height;
  BodyArea area(BodyArea r) => BodyArea(x(r.cx), y(r.cy), r.rx * sx, r.ry * sy);
  final body = next.body;
  final band = body?.legBand;
  return next.copyWith(
    slims: [for (final s in next.slims) s.copyWith(y: y(s.y), left: x(s.left), right: x(s.right))],
    heightBand: (y(next.heightBand.$1).clamp(0.0, 1.0), y(next.heightBand.$2).clamp(0.0, 1.0)),
    body: body == null
        ? null
        : BodyAnchors(
            waist: area(body.waist),
            hips: area(body.hips),
            legs: [for (final l in body.legs) area(l)],
            legBand: band == null ? null : (y(band.$1), y(band.$2)),
            found: body.found,
          ),
  );
}
