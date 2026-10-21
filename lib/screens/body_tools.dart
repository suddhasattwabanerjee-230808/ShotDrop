import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../edit/body.dart';
import '../edit/render.dart';
import '../edit/reshape.dart';
import '../models.dart';
import '../theme.dart';

/// The Body tab's four tools, each opened on its own with Cancel / Apply.
enum BodyTool {
  stretch('Stretch', 'Longer legs, taller look'),
  slim('Slim', 'Draws the waist in'),
  hips('Hip', 'Fuller, lifted hips'),
  legs('Legs', 'Straightens bowed legs');

  const BodyTool(this.label, this.hint);
  final String label, hint;

  double value(EditParams p) => switch (this) {
    stretch => p.height / maxStretch,
    slim => p.slim,
    hips => p.hips,
    legs => p.legs,
  };

  EditParams withValue(EditParams p, double v) => switch (this) {
    stretch => p.copyWith(height: v * maxStretch),
    slim => p.copyWith(slim: v),
    hips => p.copyWith(hips: v),
    legs => p.copyWith(legs: v),
  };
}

enum PoseStatus { detecting, found, notFound }

// --- The photo, with the active tool's area over it ---------------------------------

/// The finished photo (body tools and colour applied). With a tool open it
/// shows where that tool acts: Stretch's two lines, or the area Slim / Hip /
/// Legs reshape, all of which can be dragged.
class BodyStage extends StatefulWidget {
  const BodyStage({
    super.key,
    required this.image,
    required this.params,
    required this.tool,
    required this.onLive,
    required this.onCommit,
    this.top = 56,
  });

  final ui.Image image; // the cropped photo
  final EditParams params;
  final BodyTool? tool;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;
  final double top;

  @override
  State<BodyStage> createState() => _BodyStageState();
}

class _BodyStageState extends State<BodyStage> {
  int? _line; // Stretch: 0 top line, 1 bottom line
  int? _area; // Slim / Hip / Legs: which area is being moved
  Offset? _last;

  List<BodyArea> _areas(EditParams p) => switch (widget.tool) {
    BodyTool.slim => [p.bodyOrDefault.waist],
    BodyTool.hips => [p.bodyOrDefault.hips],
    BodyTool.legs => p.bodyOrDefault.legs,
    _ => const [],
  };

  EditParams _withArea(EditParams p, int i, BodyArea a) {
    final body = p.bodyOrDefault;
    return p.copyWith(
      body: switch (widget.tool) {
        BodyTool.slim => body.copyWith(waist: a),
        BodyTool.hips => body.copyWith(hips: a),
        _ => body.copyWith(legs: [for (final (j, l) in body.legs.indexed) j == i ? a : l]),
      },
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final p = widget.params;
      final size = finishedSize(Size(widget.image.width.toDouble(), widget.image.height.toDouble()), p);
      final rect = fitRect(size, box.biggest, pad: 16, top: widget.top);
      final yWarp = stretchWarp(p);
      return GestureDetector(
        onPanStart: (d) {
          final pos = d.localPosition;
          _line = _area = null;
          _last = pos;
          if (widget.tool == BodyTool.stretch) {
            final ys = [p.heightBand.$1, p.heightBand.$2].map((v) => rect.top + yWarp.map(v) * rect.height).toList();
            final near = (ys[0] - pos.dy).abs() <= (ys[1] - pos.dy).abs() ? 0 : 1;
            if ((ys[near] - pos.dy).abs() < 48) _line = near;
          } else {
            final areas = _areas(p);
            var best = double.infinity;
            for (final (i, a) in areas.indexed) {
              final c = Offset(rect.left + a.cx * rect.width, rect.top + yWarp.map(a.cy) * rect.height);
              final dist = (c - pos).distance;
              if (dist < best && dist < math.max(64, a.rx * rect.width * 1.2)) {
                best = dist;
                _area = i;
              }
            }
          }
          if (_line != null || _area != null) HapticFeedback.selectionClick();
        },
        onPanUpdate: (d) {
          final pos = d.localPosition;
          final line = _line, area = _area;
          if (line != null) {
            final v = yWarp.unmap(((pos.dy - rect.top) / rect.height).clamp(0.0, 1.0));
            final band = line == 0
                ? (math.min(v, p.heightBand.$2 - 0.05), p.heightBand.$2)
                : (p.heightBand.$1, math.max(v, p.heightBand.$1 + 0.05));
            widget.onLive(p.copyWith(heightBand: band));
          } else if (area != null) {
            final delta = pos - (_last ?? pos);
            final a = _areas(p)[area].moved(delta.dx / rect.width, delta.dy / rect.height);
            widget.onLive(_withArea(p, area, a));
          }
          _last = pos;
        },
        onPanEnd: (_) {
          _line = _area = null;
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _BodyPainter(
            image: widget.image,
            params: p,
            rect: rect,
            tool: widget.tool,
            areas: _areas(p),
            yWarp: yWarp,
          ),
        ),
      );
    },
  );
}

class _BodyPainter extends CustomPainter {
  _BodyPainter({
    required this.image,
    required this.params,
    required this.rect,
    required this.tool,
    required this.areas,
    required this.yWarp,
  });

  final ui.Image image;
  final EditParams params;
  final Rect rect;
  final BodyTool? tool;
  final List<BodyArea> areas;
  final BandWarp yWarp;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(rect.left, rect.top);
    paintFinish(canvas, image, rect.size, params);
    canvas.restore();

    final edge = Paint()
      ..color = accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    if (tool == BodyTool.stretch) {
      final top = rect.top + yWarp.map(params.heightBand.$1) * rect.height;
      final bottom = rect.top + yWarp.map(params.heightBand.$2) * rect.height;
      canvas.drawRect(
        Rect.fromLTRB(rect.left, top, rect.right, bottom),
        Paint()..color = accent.withValues(alpha: 0.1),
      );
      for (final y in [top, bottom]) {
        canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), edge);
        _handle(canvas, Offset(rect.center.dx, y));
      }
      // Double arrow between the lines, like a height marker.
      final x = rect.right - 22;
      final arrow = Paint()
        ..color = accent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      if (bottom - top > 40) {
        canvas.drawLine(Offset(x, top + 10), Offset(x, bottom - 10), arrow);
        for (final (y, s) in [(top + 10, 1.0), (bottom - 10, -1.0)]) {
          canvas.drawLine(Offset(x, y), Offset(x - 6, y + 7 * s), arrow);
          canvas.drawLine(Offset(x, y), Offset(x + 6, y + 7 * s), arrow);
        }
      }
    } else if (tool != null) {
      for (final a in areas) {
        final c = Offset(rect.left + a.cx * rect.width, rect.top + yWarp.map(a.cy) * rect.height);
        final r = Rect.fromCenter(center: c, width: a.rx * rect.width * 1.4, height: a.ry * rect.height * 1.6);
        _dashedOval(canvas, r, edge);
        canvas.drawCircle(c, 9, Paint()..color = accent);
        canvas.drawCircle(c, 3.5, Paint()..color = onAccent);
      }
    }
  }

  static void _handle(Canvas canvas, Offset c) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 44, height: 18), const Radius.circular(9));
    canvas.drawRRect(r, Paint()..color = accent);
    final grip = Paint()
      ..color = onAccent
      ..strokeWidth = 1.6;
    for (final d in [-6.0, 0.0, 6.0]) {
      canvas.drawLine(c + Offset(d, -4), c + Offset(d, 4), grip);
    }
  }

  static void _dashedOval(Canvas canvas, Rect r, Paint paint) {
    final path = Path()..addOval(r);
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 14) {
        canvas.drawPath(m.extractPath(d, math.min(d + 8, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.image != image || old.params != params || old.rect != rect || old.tool != tool;
}

// --- The panel under the photo -----------------------------------------------------

/// Closed: the four tools in a row (like Cymera). Open: that tool's 0–100
/// slider, with Cancel / Apply.
class BodyPanel extends StatelessWidget {
  const BodyPanel({
    super.key,
    required this.params,
    required this.tool,
    required this.pose,
    required this.onOpen,
    required this.onLive,
    required this.onCancel,
    required this.onApply,
  });

  final EditParams params;
  final BodyTool? tool;
  final PoseStatus pose;
  final ValueChanged<BodyTool> onOpen;
  final ValueChanged<EditParams> onLive;
  final VoidCallback onCancel, onApply;

  @override
  Widget build(BuildContext context) {
    final t = tool;
    if (t == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PoseLine(status: pose),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final b in BodyTool.values)
                _ToolButton(tool: b, active: b.value(params) > 0.005, onTap: () => onOpen(b)),
            ],
          ),
          const SizedBox(height: 12),
        ],
      );
    }
    final v = t.value(params).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            t == BodyTool.stretch
                ? 'Drag the two lines to the part to lengthen (legs work best), then slide.'
                : pose == PoseStatus.found
                ? '${t.hint}. The circle is on the body: drag it if it\'s off.'
                : '${t.hint}. Drag the circle onto the body, then slide.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600, height: 1.35),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: v,
                  onChanged: (x) => onLive(t.withValue(params, x)),
                  onChangeStart: (_) => HapticFeedback.selectionClick(),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${(v * 100).round()}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(96, 44)),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
              Expanded(
                child: Text(
                  t.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PoseLine extends StatelessWidget {
  const _PoseLine({required this.status});
  final PoseStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (status) {
      PoseStatus.detecting => (null, 'Finding the body…', muted),
      PoseStatus.found => (Icons.person_search_rounded, 'Body found: the tools know where to work', positive),
      PoseStatus.notFound => (Icons.touch_app_rounded, 'No person found: you\'ll place each tool by hand', muted),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon == null)
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
        ),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.tool, required this.active, required this.onTap});
  final BodyTool tool;
  final bool active; // already applied to this photo
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(size: const Size(52, 52), painter: _ToolIcon(tool, active ? accent : ink)),
              if (active)
                Positioned(
                  right: -4,
                  top: -2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            tool.label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: active ? accent : ink),
          ),
        ],
      ),
    ),
  );
}

/// Line-art icons in the style of Cymera's body tools.
class _ToolIcon extends CustomPainter {
  _ToolIcon(this.tool, this.color);
  final BodyTool tool;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 52;
    canvas.scale(s);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void arrowHead(Offset tip, Offset dir) {
      final n = Offset(-dir.dy, dir.dx);
      canvas.drawLine(tip, tip - dir * 5 + n * 4, p);
      canvas.drawLine(tip, tip - dir * 5 - n * 4, p);
    }

    switch (tool) {
      case BodyTool.stretch:
        // Two legs, and a double arrow beside them.
        for (final x in [10.0, 18.0, 22.0, 30.0]) {
          canvas.drawPath(
            Path()
              ..moveTo(x, 6)
              ..cubicTo(x + (x < 20 ? 1 : -1), 22, x + (x < 20 ? 2 : -2), 34, x + (x < 20 ? 1 : -1), 46),
            p,
          );
        }
        final dash = Paint()
          ..color = color
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
        for (var y = 12.0; y < 40; y += 6) {
          canvas.drawLine(Offset(42, y), Offset(42, y + 3), dash);
        }
        arrowHead(const Offset(42, 6), const Offset(0, -1));
        arrowHead(const Offset(42, 46), const Offset(0, 1));
      case BodyTool.slim:
        // A waist, with arrows pushing in from both sides.
        canvas.drawPath(
          Path()
            ..moveTo(14, 6)
            ..cubicTo(22, 18, 22, 30, 14, 46),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(38, 6)
            ..cubicTo(30, 18, 30, 30, 38, 46),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(18, 10)
            ..quadraticBezierTo(26, 14, 34, 10),
          p,
        );
        canvas.drawLine(const Offset(2, 27), const Offset(11, 27), p);
        arrowHead(const Offset(12, 27), const Offset(1, 0));
        canvas.drawLine(const Offset(50, 27), const Offset(41, 27), p);
        arrowHead(const Offset(40, 27), const Offset(-1, 0));
      case BodyTool.hips:
        // Waist curving out into hips, with an arrow lifting them.
        canvas.drawPath(
          Path()
            ..moveTo(16, 6)
            ..cubicTo(20, 16, 6, 28, 10, 44),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(36, 6)
            ..cubicTo(32, 16, 46, 28, 42, 44),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(14, 32)
            ..quadraticBezierTo(26, 42, 38, 32),
          p,
        );
        canvas.drawLine(const Offset(26, 30), const Offset(26, 18), p);
        arrowHead(const Offset(26, 17), const Offset(0, -1));
      case BodyTool.legs:
        // Two bowed legs, with arrows bringing the knees in.
        for (final x in [16.0, 36.0]) {
          final o = x < 26 ? -1.0 : 1.0;
          canvas.drawPath(
            Path()
              ..moveTo(x, 4)
              ..quadraticBezierTo(x + o * 7, 26, x, 48),
            p,
          );
        }
        canvas.drawLine(const Offset(2, 26), const Offset(8, 26), p);
        arrowHead(const Offset(9, 26), const Offset(1, 0));
        canvas.drawLine(const Offset(50, 26), const Offset(44, 26), p);
        arrowHead(const Offset(43, 26), const Offset(-1, 0));
    }
  }

  @override
  bool shouldRepaint(_ToolIcon old) => old.tool != tool || old.color != color;
}
