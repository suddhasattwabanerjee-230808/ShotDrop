import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../edit/render.dart';
import '../models.dart';
import '../theme.dart';

/// What Remove People is up to, for [RemovePeopleOverlay].
class RemovalView {
  RemovalView({required this.title, this.detail = '', this.progress});

  String title, detail;
  double? progress; // 0..1, null: not known yet

  /// The people found, as rects 0..1 in the photo as shown (turned and flipped).
  List<Rect> removing = const [], keeping = const [];

  /// The result, once it's ready: the overlay wipes it in, then says [done].
  ui.Image? after;
  String done = '';
}

/// Shown over the editor's photo while Remove People works: a scan sweeping
/// the photo while people are looked for, then the ones being removed
/// pulsing (and the ones staying ringed) while the background is rebuilt,
/// then the result wiping in across the photo.
class RemovePeopleOverlay extends StatefulWidget {
  const RemovePeopleOverlay({
    super.key,
    required this.before,
    required this.params,
    required this.view,
    required this.onCancel,
    required this.onRevealed,
  });

  final ui.Image before;
  final EditParams params; // only the turn and flip are used: the whole photo is shown
  final RemovalView view;
  final VoidCallback onCancel;
  final VoidCallback onRevealed;

  @override
  State<RemovePeopleOverlay> createState() => _RemovePeopleOverlayState();
}

class _RemovePeopleOverlayState extends State<RemovePeopleOverlay> with TickerProviderStateMixin {
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _revealing = false, _shownDone = false;

  @override
  void didUpdateWidget(RemovePeopleOverlay old) {
    super.didUpdateWidget(old);
    _maybeReveal();
  }

  @override
  void initState() {
    super.initState();
    _maybeReveal();
  }

  void _maybeReveal() {
    if (_revealing || widget.view.after == null) return;
    _revealing = true;
    _reveal.forward(from: 0).whenComplete(() async {
      if (!mounted) return;
      setState(() => _shownDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) widget.onRevealed();
    });
  }

  @override
  void dispose() {
    _loop.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return ColoredBox(
      color: paper,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_loop, _reveal]),
            builder: (context, _) => CustomPaint(
              painter: _RemovalPainter(
                before: widget.before,
                after: v.after,
                params: EditParams(quarterTurns: widget.params.quarterTurns, flipH: widget.params.flipH),
                t: _loop.value,
                reveal: Curves.easeInOutCubic.transform(_reveal.value),
                removing: v.removing,
                keeping: v.keeping,
                scanning: v.removing.isEmpty && v.keeping.isEmpty && v.after == null,
                accent: accent,
                remove: coral,
                keep: grass,
                glow: sunny,
              ),
              size: Size.infinite,
            ),
          ),
          Positioned(left: 16, right: 16, bottom: 16, child: _card(v)),
        ],
      ),
    );
  }

  Widget _card(RemovalView v) {
    final done = _shownDone;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: done ? positive : line, width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Row(
        children: [
          _badge(done),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  done ? v.done : v.title,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ink),
                ),
                if (!done && v.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    v.detail,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted),
                  ),
                ],
                if (!done) ...[const SizedBox(height: 10), _RainbowBar(value: v.progress, t: _loop)],
              ],
            ),
          ),
          if (!done && v.after == null)
            TextButton(
              onPressed: widget.onCancel,
              child: Text(
                'Cancel',
                style: TextStyle(color: muted, fontWeight: FontWeight.w700),
              ),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _badge(bool done) => AnimatedBuilder(
    animation: _loop,
    builder: (context, _) => Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: done
            ? LinearGradient(colors: [positive, grass])
            : SweepGradient(
                colors: [...rainbow, rainbow.first],
                transform: GradientRotation(_loop.value * 2 * math.pi),
              ),
      ),
      child: Center(
        child: done
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 28)
            : Transform.scale(
                scale: 0.9 + 0.12 * math.sin(_loop.value * 2 * math.pi * 2),
                child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 24),
              ),
      ),
    ),
  );
}

/// A rounded progress bar in the rainbow, shimmering; indeterminate (a
/// sliding blob) while [value] is null.
class _RainbowBar extends StatelessWidget {
  const _RainbowBar({required this.value, required this.t});
  final double? value;
  final Animation<double> t;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      height: 10,
      child: LayoutBuilder(
        builder: (context, box) => AnimatedBuilder(
          animation: t,
          builder: (context, _) {
            final w = box.maxWidth;
            final v = value;
            final left = v == null ? (w * 1.3 * t.value - w * 0.3) : 0.0;
            final width = v == null ? w * 0.3 : w * v.clamp(0.03, 1.0);
            return Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: surfaceHigh)),
                AnimatedPositioned(
                  duration: Duration(milliseconds: v == null ? 0 : 300),
                  left: left,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        colors: rainbow,
                        transform: GradientRotation(t.value * 2 * math.pi * 0.05),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _RemovalPainter extends CustomPainter {
  _RemovalPainter({
    required this.before,
    required this.after,
    required this.params,
    required this.t,
    required this.reveal,
    required this.removing,
    required this.keeping,
    required this.scanning,
    required this.accent,
    required this.remove,
    required this.keep,
    required this.glow,
  });

  final ui.Image before;
  final ui.Image? after;
  final EditParams params;
  final double t, reveal;
  final List<Rect> removing, keeping;
  final bool scanning;
  final Color accent, remove, keep, glow;

  @override
  void paint(Canvas canvas, Size size) {
    final o = orientedSize(Size(before.width.toDouble(), before.height.toDouble()), params);
    // Above the status card at the bottom.
    final fit = fitRect(o, Size(size.width, math.max(1, size.height - 118)), pad: 20);
    final frame = RRect.fromRectAndRadius(fit, const Radius.circular(22));

    // The photo, and the result wiping in over it from the left.
    canvas.drawRRect(
      frame.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.save();
    canvas.clipRRect(frame);
    _photo(canvas, before, fit, o);
    final a = after;
    final edge = fit.left + fit.width * reveal;
    if (a != null && reveal > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(fit.left, fit.top, edge, fit.bottom));
      _photo(canvas, a, fit, o);
      canvas.restore();
    }

    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 2);
    if (a == null) {
      // A soft veil, so the outlines and sparkles read on any photo.
      canvas.drawRect(fit, Paint()..color = Colors.black.withValues(alpha: 0.12));
      if (scanning) _scan(canvas, fit);
      for (final r in removing) {
        _person(canvas, _place(r, fit), remove, pulse, dust: true);
      }
      for (final r in keeping) {
        _person(canvas, _place(r, fit), keep, 0.75, dust: false);
      }
    }
    _sparkles(canvas, fit, a != null && reveal < 1 ? 0.4 : 1);
    if (a != null && reveal > 0 && reveal < 1) _wipeEdge(canvas, fit, edge);
    canvas.restore();
  }

  void _photo(Canvas canvas, ui.Image image, Rect fit, Size o) {
    canvas.save();
    canvas.translate(fit.left, fit.top);
    canvas.scale(fit.width / o.width, fit.height / o.height);
    paintOriented(canvas, image, params, o);
    canvas.restore();
  }

  Rect _place(Rect r, Rect fit) => Rect.fromLTRB(
    fit.left + r.left * fit.width,
    fit.top + r.top * fit.height,
    fit.left + r.right * fit.width,
    fit.top + r.bottom * fit.height,
  );

  /// A bright band sweeping down and up the photo.
  void _scan(Canvas canvas, Rect fit) {
    final y = fit.top + fit.height * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
    final band = Rect.fromLTRB(fit.left, y - 70, fit.right, y + 70);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.28), accent.withValues(alpha: 0)],
        ).createShader(band),
    );
    canvas.drawLine(
      Offset(fit.left, y),
      Offset(fit.right, y),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
    );
  }

  /// A rounded ring round someone: glowing, and for the ones going, magic
  /// dust drifting up through them.
  void _person(Canvas canvas, Rect r, Color c, double strength, {required bool dust}) {
    final rr = RRect.fromRectAndRadius(r.inflate(4), Radius.circular(math.min(18, r.shortestSide / 3)));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = c.withValues(alpha: 0.25 + 0.3 * strength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = c.withValues(alpha: 0.6 + 0.4 * strength),
    );
    if (dust) {
      canvas.save();
      canvas.clipRRect(rr);
      canvas.drawRRect(rr, Paint()..color = c.withValues(alpha: 0.10 + 0.08 * strength));
      final rnd = math.Random(r.left.round() * 31 + r.top.round());
      for (var i = 0; i < 14; i++) {
        final phase = (t + rnd.nextDouble()) % 1;
        final p = Offset(r.left + rnd.nextDouble() * r.width, r.bottom - phase * r.height);
        canvas.drawCircle(
          p,
          1.5 + 2.5 * rnd.nextDouble(),
          Paint()..color = Colors.white.withValues(alpha: 0.85 * (1 - phase)),
        );
      }
      canvas.restore();
    } else {
      // A little heart badge: this one stays.
      final at = Offset(r.center.dx, r.top - 2);
      canvas.drawCircle(at, 13, Paint()..color = c);
      final icon = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.favorite_rounded.codePoint),
          style: TextStyle(fontSize: 15, fontFamily: Icons.favorite_rounded.fontFamily, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      icon.paint(canvas, at - Offset(icon.width / 2, icon.height / 2));
    }
  }

  /// Four-pointed stars twinkling over the photo.
  void _sparkles(Canvas canvas, Rect fit, double alpha) {
    final rnd = math.Random(7);
    for (var i = 0; i < 18; i++) {
      final p = Offset(fit.left + rnd.nextDouble() * fit.width, fit.top + rnd.nextDouble() * fit.height);
      final phase = (t * (0.8 + rnd.nextDouble()) + rnd.nextDouble()) % 1;
      final s = math.sin(phase * math.pi);
      if (s < 0.2) continue;
      _star(
        canvas,
        p,
        3 + 7 * s * rnd.nextDouble() + 3 * s,
        (i.isEven ? Colors.white : glow).withValues(alpha: alpha * s),
      );
    }
  }

  void _star(Canvas canvas, Offset c, double r, Color color) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// The glowing line the result wipes in behind, shedding stars.
  void _wipeEdge(Canvas canvas, Rect fit, double x) {
    final glowRect = Rect.fromLTRB(x - 40, fit.top, x + 6, fit.bottom);
    canvas.drawRect(
      glowRect,
      Paint()
        ..shader = LinearGradient(colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.45)])
            .createShader(glowRect),
    );
    canvas.drawLine(
      Offset(x, fit.top),
      Offset(x, fit.bottom),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4),
    );
    final rnd = math.Random(3);
    for (var i = 0; i < 10; i++) {
      final y = fit.top + rnd.nextDouble() * fit.height;
      final d = 6 + rnd.nextDouble() * 22 * reveal;
      _star(
        canvas,
        Offset(x - d, y),
        3 + rnd.nextDouble() * 6,
        (i.isEven ? Colors.white : glow).withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_RemovalPainter old) => true; // animated every frame
}
