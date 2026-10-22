import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Little cartoon stickers sprinkled round the app: drawn in code, so they
/// need no image files and follow the light / dark palette.
enum PropKind { lion, kite, balloon, cloud, plane, bird, butterfly, rainbow }

/// Width : height of each prop's box.
double propAspect(PropKind k) => switch (k) {
  PropKind.kite => 0.58,
  PropKind.balloon => 0.62,
  PropKind.cloud => 1.6,
  PropKind.plane => 1.3,
  PropKind.rainbow => 1.7,
  _ => 1.0,
};

// The cartoon outline, the same dark grape in both modes: stickers.
const _outline = Color(0xFF2D1E4F);

/// Paints [kind] into [box]. [t] (0..1, looping) moves the bits that wiggle:
/// the kite's tail, the butterfly's wings, the balloon's string.
void paintProp(Canvas canvas, PropKind kind, Rect box, {double t = 0.5, Color? tint}) {
  canvas.save();
  canvas.translate(box.left, box.top);
  final w = box.width, h = box.height;
  final line = Paint()
    ..color = _outline
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.2, w * 0.05)
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  Paint fill(Color c) => Paint()..color = c;
  void shape(Path p, Color c) {
    canvas.drawPath(p, fill(c));
    canvas.drawPath(p, line);
  }

  // Draws [circles] as one blob with a single outline round the lot: the
  // outlines go down first at double width, the fills on top hide the inner ones.
  void blob(List<(Offset, double)> circles, Color c) {
    final thick = Paint()
      ..color = _outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = line.strokeWidth * 2;
    for (final (o, r) in circles) {
      canvas.drawCircle(o, r, thick);
    }
    for (final (o, r) in circles) {
      canvas.drawCircle(o, r, fill(c));
    }
  }

  void eye(Offset o, double r) {
    canvas.drawCircle(o, r, fill(_outline));
    canvas.drawCircle(o + Offset(-r * 0.35, -r * 0.35), r * 0.38, fill(Colors.white));
  }

  final wave = math.sin(t * 2 * math.pi);
  switch (kind) {
    case PropKind.lion:
      final c = Offset(w / 2, h / 2);
      // Mane: a ring of puffs.
      blob([
        (c, w * 0.36),
        for (var i = 0; i < 12; i++) (c + Offset.fromDirection(i * math.pi / 6, w * 0.36), w * 0.11),
      ], tangerine);
      // Ears.
      for (final s in [-1.0, 1.0]) {
        final e = c + Offset(s * w * 0.2, -w * 0.21);
        canvas.drawCircle(e, w * 0.085, fill(sunny));
        canvas.drawCircle(e, w * 0.085, line);
        canvas.drawCircle(e, w * 0.04, fill(coral));
      }
      canvas.drawCircle(c + Offset(0, w * 0.02), w * 0.26, fill(sunny));
      canvas.drawCircle(c + Offset(0, w * 0.02), w * 0.26, line);
      // Cheeks, eyes, muzzle, nose, smile.
      for (final s in [-1.0, 1.0]) {
        canvas.drawCircle(c + Offset(s * w * 0.15, w * 0.09), w * 0.05, fill(coral.withValues(alpha: 0.55)));
        eye(c + Offset(s * w * 0.095, -w * 0.035), w * 0.035);
      }
      canvas.drawOval(
        Rect.fromCenter(center: c + Offset(0, w * 0.1), width: w * 0.24, height: w * 0.15),
        fill(const Color(0xFFFFF1C9)),
      );
      final nose = Path()
        ..moveTo(c.dx - w * 0.055, c.dy + w * 0.045)
        ..lineTo(c.dx + w * 0.055, c.dy + w * 0.045)
        ..quadraticBezierTo(c.dx, c.dy + w * 0.13, c.dx - w * 0.055, c.dy + w * 0.045)
        ..close();
      canvas.drawPath(nose, fill(deeper(tangerine, 0.25)));
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - w * 0.07, c.dy + w * 0.13)
          ..quadraticBezierTo(c.dx - w * 0.035, c.dy + w * 0.17, c.dx, c.dy + w * 0.12)
          ..quadraticBezierTo(c.dx + w * 0.035, c.dy + w * 0.17, c.dx + w * 0.07, c.dy + w * 0.13),
        line..strokeWidth = line.strokeWidth * 0.7,
      );

    case PropKind.kite:
      final top = Offset(w * 0.5, w * 0.03), right = Offset(w * 0.92, w * 0.3);
      final bottom = Offset(w * 0.5, w * 0.84), left = Offset(w * 0.08, w * 0.3);
      final mid = Offset(w * 0.5, w * 0.3);
      // Four panes in two colours, then the outline and the cross spars.
      for (final (a, b, col) in [
        (top, right, accent),
        (right, bottom, sunny),
        (bottom, left, accent),
        (left, top, sunny),
      ]) {
        canvas.drawPath(Path()..addPolygon([mid, a, b], true), fill(col));
      }
      canvas.drawPath(Path()..addPolygon([top, right, bottom, left], true), line);
      final spar = Paint()
        ..color = _outline.withValues(alpha: 0.6)
        ..strokeWidth = line.strokeWidth * 0.6;
      canvas.drawLine(top, bottom, spar);
      canvas.drawLine(left, right, spar);
      // A wavy tail with bows, waving with t.
      final tail = Path()..moveTo(bottom.dx, bottom.dy);
      final bows = <Offset>[];
      final seg = (h - bottom.dy - w * 0.1) / 3;
      for (var i = 0; i < 3; i++) {
        final y0 = bottom.dy + seg * i;
        final sway = (i.isEven ? 1 : -1) * w * 0.16 * (0.6 + 0.4 * wave);
        final end = Offset(w * 0.5 + (i + 1) * w * 0.03 * wave, y0 + seg);
        tail.quadraticBezierTo(w * 0.5 + sway, y0 + seg / 2, end.dx, end.dy);
        bows.add(end);
      }
      canvas.drawPath(tail, line..strokeWidth = line.strokeWidth * 0.7);
      for (final (i, b) in bows.indexed) {
        final s = w * 0.09;
        final bow = Path()
          ..addPolygon([b, b + Offset(-s, -s * 0.7), b + Offset(-s, s * 0.7)], true)
          ..addPolygon([b, b + Offset(s, -s * 0.7), b + Offset(s, s * 0.7)], true);
        canvas.drawPath(bow, fill([grass, sky, grape][i]));
      }

    case PropKind.balloon:
      final body = Rect.fromLTWH(w * 0.06, w * 0.04, w * 0.88, w * 1.04);
      // String first, so the knot sits on it.
      final start = body.bottom + w * 0.1, rest = h - start;
      final s = Path()..moveTo(w * 0.5, start);
      s.cubicTo(
        w * (0.5 + 0.22 * wave),
        start + rest * 0.35,
        w * (0.5 - 0.22 * wave),
        start + rest * 0.65,
        w * 0.5,
        h - w * 0.04,
      );
      canvas.drawPath(s, Paint.from(line)..strokeWidth = line.strokeWidth * 0.6);
      shape(
        Path()..addPolygon([
          Offset(w * 0.5, body.bottom - w * 0.02),
          Offset(w * 0.4, body.bottom + w * 0.12),
          Offset(w * 0.6, body.bottom + w * 0.12),
        ], true),
        deeper(tint ?? coral, 0.1),
      );
      shape(Path()..addOval(body), tint ?? coral);
      canvas.drawOval(Rect.fromLTWH(w * 0.22, w * 0.2, w * 0.18, w * 0.3), fill(Colors.white.withValues(alpha: 0.7)));

    case PropKind.cloud:
      final cloud = const Color(0xFFFFFFFF);
      blob([
        (Offset(w * 0.28, h * 0.62), h * 0.26),
        (Offset(w * 0.47, h * 0.42), h * 0.33),
        (Offset(w * 0.7, h * 0.52), h * 0.28),
        (Offset(w * 0.82, h * 0.68), h * 0.2),
        (Offset(w * 0.16, h * 0.72), h * 0.16),
        (Offset(w * 0.5, h * 0.7), h * 0.22),
      ], cloud);
      for (final x in [0.42, 0.6]) {
        eye(Offset(w * x, h * 0.55), h * 0.06);
      }
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.46, h * 0.68)
          ..quadraticBezierTo(w * 0.51, h * 0.76, w * 0.56, h * 0.68),
        Paint.from(line)..strokeWidth = line.strokeWidth * 0.7,
      );
      for (final x in [0.34, 0.68]) {
        canvas.drawCircle(Offset(w * x, h * 0.66), h * 0.06, fill(accent.withValues(alpha: 0.4)));
      }

    case PropKind.plane:
      // A dashed swoosh behind it.
      final dash = Paint.from(line)
        ..color = sky
        ..strokeWidth = line.strokeWidth * 0.8;
      for (var i = 0; i < 3; i++) {
        final x = w * (0.02 + i * 0.12);
        canvas.drawLine(Offset(x, h * (0.86 - i * 0.07)), Offset(x + w * 0.07, h * (0.83 - i * 0.07)), dash);
      }
      // Top wing, lower wing, then the keel folded under.
      final nose = Offset(w * 0.96, h * 0.16), back = Offset(w * 0.28, h * 0.22);
      final fold = Offset(w * 0.5, h * 0.52), tail = Offset(w * 0.44, h * 0.88);
      shape(Path()..addPolygon([nose, back, fold], true), Colors.white);
      shape(Path()..addPolygon([nose, fold, tail], true), const Color(0xFFDDEBFF));
      shape(Path()..addPolygon([nose, fold, Offset(w * 0.56, h * 0.64)], true), sky);

    case PropKind.bird:
      final c = Offset(w * 0.5, h * 0.56);
      // Tail, body, belly, wing, beak, eye, tuft.
      shape(
        Path()..addPolygon([
          c + Offset(-w * 0.26, 0),
          c + Offset(-w * 0.46, -w * 0.12),
          c + Offset(-w * 0.44, w * 0.08),
        ], true),
        deeper(sky, 0.12),
      );
      canvas.drawCircle(c, w * 0.3, fill(sky));
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: w * 0.3)));
      canvas.drawCircle(c + Offset(w * 0.06, w * 0.24), w * 0.22, fill(const Color(0xFFE6F4FF)));
      canvas.restore();
      canvas.drawCircle(c, w * 0.3, line);
      // Legs, beak, and a wing flapping back towards the tail.
      for (final x in [-0.06, 0.06]) {
        canvas.drawLine(
          c + Offset(w * x, w * 0.29),
          c + Offset(w * x, w * 0.38),
          Paint.from(line)
            ..color = tangerine
            ..strokeWidth = line.strokeWidth * 0.9,
        );
      }
      shape(
        Path()..addPolygon([
          c + Offset(w * 0.28, -w * 0.08),
          c + Offset(w * 0.46, -w * 0.01),
          c + Offset(w * 0.27, w * 0.06),
        ], true),
        tangerine,
      );
      final wing = Path()
        ..moveTo(c.dx + w * 0.06, c.dy - w * 0.02)
        ..quadraticBezierTo(c.dx - w * 0.1, c.dy - w * (0.16 + 0.08 * wave), c.dx - w * 0.26, c.dy - w * 0.04)
        ..quadraticBezierTo(c.dx - w * 0.1, c.dy + w * 0.16, c.dx + w * 0.06, c.dy - w * 0.02)
        ..close();
      shape(wing, deeper(sky, 0.12));
      eye(c + Offset(w * 0.13, -w * 0.1), w * 0.045);
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - w * 0.02, c.dy - w * 0.29)
          ..quadraticBezierTo(c.dx - w * 0.06, c.dy - w * 0.42, c.dx + w * 0.06, c.dy - w * 0.4),
        Paint.from(line)..strokeWidth = line.strokeWidth * 0.8,
      );

    case PropKind.butterfly:
      final c = Offset(w / 2, h / 2);
      final flap = 0.72 + 0.28 * (0.5 + 0.5 * wave); // wings open and close
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(flap, 1);
      for (final s in [-1.0, 1.0]) {
        final up = Rect.fromCenter(center: Offset(s * w * 0.22, -w * 0.13), width: w * 0.42, height: w * 0.44);
        final low = Rect.fromCenter(center: Offset(s * w * 0.17, w * 0.2), width: w * 0.3, height: w * 0.32);
        shape(Path()..addOval(low), sunny);
        shape(Path()..addOval(up), grape);
        canvas.drawCircle(
          up.center + Offset(s * w * 0.03, -w * 0.02),
          w * 0.07,
          fill(Colors.white.withValues(alpha: 0.8)),
        );
      }
      canvas.restore();
      shape(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: w * 0.1, height: w * 0.62),
            Radius.circular(w * 0.05),
          ),
        ),
        _outline,
      );
      for (final s in [-1.0, 1.0]) {
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - w * 0.28)
            ..quadraticBezierTo(c.dx + s * w * 0.04, c.dy - w * 0.44, c.dx + s * w * 0.15, c.dy - w * 0.46),
          Paint.from(line)..strokeWidth = line.strokeWidth * 0.7,
        );
        canvas.drawCircle(Offset(c.dx + s * w * 0.15, c.dy - w * 0.46), w * 0.035, fill(_outline));
      }

    case PropKind.rainbow:
      final c = Offset(w / 2, h * 0.92);
      final bands = [coral, sunny, grass, sky];
      final band = h * 0.13;
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = band;
      for (final (i, col) in bands.indexed) {
        final r = w * 0.44 - band * (i + 0.5);
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), math.pi, math.pi, false, arc..color = col);
      }
      // Outline round the outside and inside edges.
      final thin = Paint.from(line)..strokeWidth = line.strokeWidth * 0.8;
      canvas.drawArc(Rect.fromCircle(center: c, radius: w * 0.44), math.pi, math.pi, false, thin);
      canvas.drawArc(Rect.fromCircle(center: c, radius: w * 0.44 - band * 4), math.pi, math.pi, false, thin);
      // A puff of cloud at each foot.
      for (final x in [0.06 + 0.04, 0.9]) {
        blob([
          (Offset(w * (x - 0.06), h * 0.86), h * 0.12),
          (Offset(w * x, h * 0.8), h * 0.16),
          (Offset(w * (x + 0.06), h * 0.87), h * 0.11),
        ], Colors.white);
      }
  }
  canvas.restore();
}

/// One prop as a widget, optionally moving: the kite sways, the balloon
/// bobs, the lion tilts its head, the butterfly flaps. Pauses while its tab
/// isn't the one showing.
class Prop extends StatefulWidget {
  const Prop(this.kind, {super.key, this.size = 36, this.animate = true, this.phase = 0, this.angle = 0, this.tint});
  final PropKind kind;
  final double size; // width
  final bool animate;
  final double phase; // 0..1, so neighbours don't move in step
  final double angle; // resting tilt, radians
  final Color? tint; // a balloon's colour (default coral)

  @override
  State<Prop> createState() => _PropState();
}

class _PropState extends State<Prop> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: _period(widget.kind), value: widget.phase);

  static Duration _period(PropKind k) => switch (k) {
    PropKind.butterfly => const Duration(milliseconds: 900),
    PropKind.bird => const Duration(milliseconds: 1400),
    PropKind.cloud || PropKind.rainbow => const Duration(seconds: 7),
    _ => const Duration(milliseconds: 3200),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = widget.animate && Visibility.of(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.size, h = w / propAspect(widget.kind);
    return IgnorePointer(
      child: RepaintBoundary(
        child: SizedBox(
          width: w,
          height: h,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value, s = math.sin(t * 2 * math.pi);
              final (dx, dy, turn) = switch (widget.kind) {
                PropKind.kite => (w * 0.06 * s, -h * 0.03 * s.abs(), 0.14 * s),
                PropKind.balloon => (0.0, -h * 0.05 * s, 0.05 * s),
                PropKind.lion => (0.0, 0.0, 0.1 * s),
                PropKind.cloud => (w * 0.05 * s, 0.0, 0.0),
                PropKind.plane => (0.0, -h * 0.06 * s, 0.05 * s),
                PropKind.bird => (0.0, -h * 0.06 * math.max(0.0, s), 0.0),
                PropKind.butterfly => (w * 0.05 * math.sin(t * math.pi), -h * 0.04 * s, 0.1),
                PropKind.rainbow => (0.0, 0.0, 0.0),
              };
              return Transform(
                alignment: widget.kind == PropKind.kite ? const Alignment(0, -0.2) : Alignment.center,
                transform: Matrix4.translationValues(dx, dy, 0)..rotateZ(widget.angle + turn),
                child: CustomPaint(painter: PropPainter(widget.kind, t, isLight, tint: widget.tint)),
              );
            },
          ),
        ),
      ),
    );
  }
}

class PropPainter extends CustomPainter {
  const PropPainter(this.kind, this.t, this.light, {this.tint});
  final PropKind kind;
  final double t;
  final bool light; // the palette in use, so a mode switch repaints
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) => paintProp(canvas, kind, Offset.zero & size, t: t, tint: tint);

  @override
  bool shouldRepaint(PropPainter old) => old.kind != kind || old.t != t || old.light != light || old.tint != tint;
}

/// A lion peeking over the top of the tab bar, paws on its edge. Every now
/// and then it pops up a little higher and tilts its head.
class PeekingLion extends StatefulWidget {
  const PeekingLion({super.key, this.size = 34});
  final double size;

  @override
  State<PeekingLion> createState() => _PeekingLionState();
}

class _PeekingLionState extends State<PeekingLion> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  // A timer, not a repeating animation, so nothing ticks between peeks.
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (TickerMode.valuesOf(context).enabled) {
      _timer = Timer.periodic(const Duration(seconds: 9), (_) => _c.forward(from: 0));
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = _c.value;
          final up = math.sin(v * math.pi); // 0 → 1 → 0
          final wag = math.sin(v * 3 * math.pi) * (1 - v);
          return Transform.translate(
            offset: Offset(0, -s * 0.18 * up),
            child: Transform.rotate(
              angle: 0.18 * wag,
              child: CustomPaint(size: Size.square(s), painter: PropPainter(PropKind.lion, 0.5, isLight)),
            ),
          );
        },
      ),
    );
  }
}

/// The lion's two paws, to sit on the edge it peeks over.
class LionPaws extends StatelessWidget {
  const LionPaws({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(size: Size(size, size * 0.28), painter: _PawsPainter(isLight)),
  );
}

class _PawsPainter extends CustomPainter {
  const _PawsPainter(this.light);
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final line = Paint()
      ..color = _outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.05);
    for (final x in [0.27, 0.73]) {
      final paw = Rect.fromCenter(center: Offset(w * x, h * 0.5), width: w * 0.26, height: h * 0.9);
      canvas.drawOval(paw, Paint()..color = sunny);
      canvas.drawOval(paw, line);
      for (final d in [-0.05, 0.05]) {
        canvas.drawLine(Offset(w * (x + d), h * 0.55), Offset(w * (x + d), h * 0.9), line..strokeWidth = w * 0.025);
      }
      line.strokeWidth = math.max(1.2, w * 0.05);
    }
  }

  @override
  bool shouldRepaint(_PawsPainter old) => old.light != light;
}

/// A lion flying a kite under a rainbow, below the last Settings section.
class KiteScene extends StatelessWidget {
  const KiteScene({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    height: 128,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: CustomPaint(painter: _StringPainter(isLight))),
        const Positioned(left: 34, bottom: 0, child: Prop(PropKind.lion, size: 58)),
        const Positioned(right: 18, top: 0, child: Prop(PropKind.kite, size: 40, angle: 0.25)),
        const Positioned(left: 0, top: 14, child: Prop(PropKind.rainbow, size: 52)),
        const Positioned(left: 104, top: 0, child: Prop(PropKind.butterfly, size: 22, phase: 0.3)),
        Positioned(right: 2, bottom: 8, child: Prop(PropKind.balloon, size: 22, phase: 0.6, tint: sky)),
      ],
    ),
  );
}

// The kite string, from the lion's paw up to the kite.
class _StringPainter extends CustomPainter {
  const _StringPainter(this.light);
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final from = Offset(92, size.height - 22), to = Offset(size.width - 38, 40);
    canvas.drawPath(
      Path()
        ..moveTo(from.dx, from.dy)
        ..quadraticBezierTo((from.dx + to.dx) / 2 + 10, (from.dy + to.dy) / 2 + 16, to.dx, to.dy),
      Paint()
        ..color = muted
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_StringPainter old) => old.light != light;
}
