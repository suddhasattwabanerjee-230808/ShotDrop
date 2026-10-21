import 'dart:math' as math;

/// Where the body tools act, in the cropped photo's normalized coordinates
/// (x across, y down, both 0..1). Found by pose detection, or defaults the
/// user drags into place.
class BodyArea {
  const BodyArea(this.cx, this.cy, this.rx, this.ry);
  final double cx, cy; // centre
  final double rx, ry; // reach across / down (the effect fades out beyond)

  BodyArea moved(double dx, double dy) => BodyArea((cx + dx).clamp(0.0, 1.0), (cy + dy).clamp(0.0, 1.0), rx, ry);

  List<double> toJson() => [cx, cy, rx, ry];
  static BodyArea? fromJson(Object? j) {
    final l = [for (final v in (j as List? ?? const [])) (v as num).toDouble()];
    return l.length == 4 ? BodyArea(l[0], l[1], l[2], l[3]) : null;
  }
}

/// The person in the photo, as the body tools need it.
class BodyAnchors {
  const BodyAnchors({required this.waist, required this.hips, required this.legs, this.legBand, this.found = false});

  final BodyArea waist; // Slim
  final BodyArea hips; // Hip
  final List<BodyArea> legs; // Legs, one per leg
  final (double, double)? legBand; // hips to ankles, for placing Stretch's lines
  final bool found; // from pose detection rather than defaults

  /// A standing person roughly in the middle of the frame.
  static const defaults = BodyAnchors(
    waist: BodyArea(0.5, 0.45, 0.24, 0.14),
    hips: BodyArea(0.5, 0.58, 0.26, 0.09),
    legs: [BodyArea(0.43, 0.8, 0.08, 0.17), BodyArea(0.57, 0.8, 0.08, 0.17)],
  );

  BodyAnchors copyWith({BodyArea? waist, BodyArea? hips, List<BodyArea>? legs}) => BodyAnchors(
    waist: waist ?? this.waist,
    hips: hips ?? this.hips,
    legs: legs ?? this.legs,
    legBand: legBand,
    found: found,
  );

  Map<String, Object?> toJson() => {
    'waist': waist.toJson(),
    'hips': hips.toJson(),
    'legs': [for (final l in legs) l.toJson()],
    if (legBand != null) 'legBand': [legBand!.$1, legBand!.$2],
    'found': found,
  };

  static BodyAnchors? fromJson(Object? j) {
    if (j is! Map) return null;
    final waist = BodyArea.fromJson(j['waist']), hips = BodyArea.fromJson(j['hips']);
    final legs = [for (final l in (j['legs'] as List? ?? const [])) ?BodyArea.fromJson(l)];
    if (waist == null || hips == null || legs.length != 2) return null;
    final band = [for (final v in (j['legBand'] as List? ?? const [])) (v as num).toDouble()];
    return BodyAnchors(
      waist: waist,
      hips: hips,
      legs: legs,
      legBand: band.length == 2 ? (band[0], band[1]) : null,
      found: j['found'] == true,
    );
  }

  /// From pose landmarks (ML Kit numbering: 11/12 shoulders, 23/24 hips,
  /// 25/26 knees, 27/28 ankles), each (x, y, confidence) normalized to the
  /// photo. Null when the shoulders and hips aren't clearly visible.
  static BodyAnchors? fromLandmarks(Map<int, (double, double, double)> lm) {
    (double, double)? p(int i, [double minConf = 0.5]) {
      final v = lm[i];
      return v != null && v.$3 >= minConf ? (v.$1, v.$2) : null;
    }

    final ls = p(11), rs = p(12), lh = p(23), rh = p(24);
    if (ls == null || rs == null || lh == null || rh == null) return null;
    final shoulderY = (ls.$2 + rs.$2) / 2, hipY = (lh.$2 + rh.$2) / 2;
    final torso = hipY - shoulderY;
    if (torso <= 0.02) return null;
    final shoulderW = (ls.$1 - rs.$1).abs(), hipW = (lh.$1 - rh.$1).abs();
    final torsoW = math.max(shoulderW, hipW * 1.3);

    final waist = BodyArea((ls.$1 + rs.$1 + lh.$1 + rh.$1) / 4, shoulderY + torso * 0.72, torsoW * 0.8, torso * 0.55);
    final hips = BodyArea((lh.$1 + rh.$1) / 2, hipY + torso * 0.12, math.max(hipW * 1.25, 0.06), torso * 0.32);

    // Legs: hip → knee → ankle on each side; guessed down from the hip if hidden.
    final legs = <BodyArea>[];
    double? bandBottom;
    for (final (hip, kneeI, ankleI) in [(lh, 25, 27), (rh, 26, 28)]) {
      final knee = p(kneeI, 0.4), ankle = p(ankleI, 0.4);
      final bottom = ankle?.$2 ?? (knee != null ? knee.$2 + (knee.$2 - hip.$2) : hip.$2 + torso * 1.6);
      final xs = [hip.$1, ?knee?.$1, ?ankle?.$1];
      final cx = xs.reduce((a, b) => a + b) / xs.length;
      final len = (bottom - hip.$2).clamp(0.05, 1.0);
      legs.add(BodyArea(cx, hip.$2 + len * 0.5, math.max(hipW * 0.45, 0.035), len * 0.55));
      if (ankle != null) bandBottom = math.max(bandBottom ?? 0, ankle.$2);
    }
    return BodyAnchors(
      waist: waist,
      hips: hips,
      legs: legs,
      legBand: (hipY.clamp(0.0, 0.95), (bandBottom ?? (hipY + torso * 1.6)).clamp(hipY + 0.05, 1.0)),
      found: true,
    );
  }
}

/// A local warp around an area, falling off smoothly so the background
/// around it bends only a little:
/// - [amount] < 0 draws the area in towards its centre line (slimmer), > 0
///   pushes it out (wider);
/// - [shift] slides it across (in reaches, + to the right), strongest at the
///   area's middle and fading out fast above and below it;
/// - [lift] moves it up (in reaches down).
class LocalWarp {
  const LocalWarp(this.area, this.amount, {this.shift = 0, this.lift = 0});
  final BodyArea area;
  final double amount, shift, lift;

  /// How far a point at ([x], [y]) moves across.
  double dx(double x, double y) {
    final u = (x - area.cx) / area.rx, v = (y - area.cy) / area.ry;
    final d = u * u + v * v;
    if (d > 9) return 0;
    return amount * (x - area.cx) * math.exp(-d) + shift * area.rx * math.exp(-u * u - 3 * v * v);
  }

  /// How far a point at ([x], [y]) moves down.
  double dy(double x, double y) {
    if (lift == 0) return 0;
    final u = (x - area.cx) / area.rx, v = (y - area.cy) / area.ry;
    final d = u * u + v * v;
    return d > 9 ? 0 : -lift * area.ry * math.exp(-d);
  }
}

// Strength at 100 on each slider.
// Strong enough to see, weak enough that the photo never folds over itself.
const maxSlim = -0.34, maxHips = 0.3, maxHipLift = 0.3, maxLegs = 0.55, maxStretch = 0.4;
