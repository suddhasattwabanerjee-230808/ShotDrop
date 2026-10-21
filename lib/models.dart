import 'dart:ui' show Rect;

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
    this.width = 0,
    this.widthBand = const (0.3, 0.7),
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

  /// Body reshape. [height] > 0 stretches [heightBand] (top..bottom, 0..1 of
  /// the cropped photo) taller, < 0 shorter. [width] > 0 widens [widthBand]
  /// (left..right), < 0 slims it. The rest of the photo absorbs the change, so
  /// the frame (and the aspect ratio picked for Instagram) stays the same.
  final double height;
  final (double, double) heightBand;
  final double width;
  final (double, double) widthBand;

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
    double? width,
    (double, double)? widthBand,
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
    width: width ?? this.width,
    widthBand: widthBand ?? this.widthBand,
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
    'width': width,
    'widthBand': [widthBand.$1, widthBand.$2],
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
    final wb = list('widthBand');
    return EditParams(
      quarterTurns: (j['quarterTurns'] as num?)?.toInt() ?? 0,
      flipH: j['flipH'] == true,
      straighten: d('straighten'),
      crop: c.length == 4 ? Rect.fromLTRB(c[0], c[1], c[2], c[3]) : const Rect.fromLTWH(0, 0, 1, 1),
      aspect: AspectPreset.values.asNameMap()[j['aspect']] ?? AspectPreset.original,
      height: d('height'),
      heightBand: hb.length == 2 ? (hb[0], hb[1]) : const (0.45, 0.9),
      width: d('width'),
      widthBand: wb.length == 2 ? (wb[0], wb[1]) : const (0.3, 0.7),
      filter: j['filter'] as String? ?? 'original',
      brightness: d('brightness'),
      contrast: d('contrast'),
      saturation: d('saturation'),
      warmth: d('warmth'),
    );
  }
}

/// A photo sitting in the Upload folder, edited and waiting to be posted.
class UploadItem {
  const UploadItem({
    required this.shotId,
    required this.name,
    required this.taken,
    required this.sourcePath,
    required this.exportPath,
    required this.params,
    this.galleryUri,
    this.published = false,
    this.width,
    this.height,
  });

  final String shotId; // CardShot.id, so the grid can tick it
  final String name; // DSC_0123
  final DateTime taken;
  final String sourcePath; // upright, untouched copy of the card JPEG
  final String exportPath; // the edited JPEG that gets posted
  final EditParams params;
  final String? galleryUri; // its copy in Pictures/ShotDrop/Upload
  final bool published;
  final int? width, height; // of the export, in pixels

  /// Width / height of the export, if known.
  double? get aspect => width != null && height != null && height! > 0 ? width! / height! : null;

  UploadItem copyWith({String? exportPath, EditParams? params, String? galleryUri, bool? published}) => UploadItem(
    shotId: shotId,
    name: name,
    taken: taken,
    sourcePath: sourcePath,
    exportPath: exportPath ?? this.exportPath,
    params: params ?? this.params,
    galleryUri: galleryUri ?? this.galleryUri,
    published: published ?? this.published,
    width: width,
    height: height,
  );

  Map<String, Object?> toJson() => {
    'shotId': shotId,
    'name': name,
    'taken': taken.millisecondsSinceEpoch,
    'sourcePath': sourcePath,
    'exportPath': exportPath,
    'params': params.toJson(),
    'galleryUri': galleryUri,
    'published': published,
    'width': width,
    'height': height,
  };

  factory UploadItem.fromJson(Map<String, Object?> j) => UploadItem(
    shotId: j['shotId'] as String,
    name: j['name'] as String,
    taken: DateTime.fromMillisecondsSinceEpoch((j['taken'] as num).toInt()),
    sourcePath: j['sourcePath'] as String,
    exportPath: j['exportPath'] as String,
    params: EditParams.fromJson((j['params'] as Map).cast<String, Object?>()),
    galleryUri: j['galleryUri'] as String?,
    published: j['published'] == true,
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
  );
}
