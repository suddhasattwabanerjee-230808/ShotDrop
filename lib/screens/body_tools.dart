import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../edit/body.dart';
import '../edit/render.dart';
import '../edit/reshape.dart';
import '../edit/shape.dart';
import '../models.dart';
import '../theme.dart';

/// The Body tab's four tools. Laid out like Cymera's Body screen (the open
/// tool's slider over the row of tools), but nothing is modal: changes show
/// as they're made, undo covers them, and Crop / Adjust stay a tap away.
/// Slim first asks for the area (a line with a bracket at each end); areas
/// already made can be tapped to change them again.
enum BodyTool {
  stretch('Stretch'),
  slim('Slim'),
  hips('Hip'),
  legs('Legs');

  const BodyTool(this.label);
  final String label;

  /// The slider runs -1..1 (centre = untouched) rather than 0..1:
  /// Stretch taller / shorter, Slim slimmer / wider.
  bool get twoWay => this == stretch || this == slim;

  /// The slider's value. Slim's is the area picked last.
  double value(EditParams p) => switch (this) {
    stretch => p.height / maxStretch,
    slim => p.slims.isEmpty ? 0 : p.slims.last.amount,
    hips => p.hips,
    legs => p.legs,
  };

  EditParams withValue(EditParams p, double v) => switch (this) {
    stretch => p.copyWith(height: v * maxStretch),
    slim =>
      p.slims.isEmpty ? p : p.copyWith(slims: [...p.slims.sublist(0, p.slims.length - 1), p.slims.last.copyWith(amount: v)]),
    hips => p.copyWith(hips: v),
    legs => p.copyWith(legs: v),
  };

  /// Already changes the photo (marked in the row).
  bool applied(EditParams p) => switch (this) {
    slim => p.slims.any((s) => s.amount.abs() > 0.005),
    _ => value(p).abs() > 0.005,
  };
}

enum PoseStatus { detecting, found, notFound }

// --- The photo, with the active tool's area over it ---------------------------------

/// The finished photo (body tools and colour applied). With a tool open it
/// shows where that tool acts: Stretch's two lines, Slim's line and
/// brackets while its area is being picked, or the area Hip / Legs reshape.
/// All of them can be dragged.
class BodyStage extends StatefulWidget {
  const BodyStage({
    super.key,
    required this.image,
    required this.params,
    required this.tool,
    required this.onLive,
    required this.onCommit,
    this.slimDraft,
    this.onSlimDraft,
    this.mask,
    this.top = 56,
  });

  final ui.Image image; // the cropped photo
  final EditParams params;
  final BodyTool? tool;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;
  final SlimArea? slimDraft; // Slim's area while it's being picked
  final ValueChanged<SlimArea>? onSlimDraft;
  final BodyMask? mask; // the person's outline, for snapping Slim's brackets to the body
  final double top;

  @override
  State<BodyStage> createState() => _BodyStageState();
}

class _BodyStageState extends State<BodyStage> {
  int? _line; // Stretch: 0 top line, 1 bottom line
  int? _area; // Hip / Legs: which area is being moved
  int? _bracket; // Slim: 0 left, 1 right, 2 the whole line
  Offset? _last;

  List<BodyArea> _areas(EditParams p) => switch (widget.tool) {
    BodyTool.hips => [p.bodyOrDefault.hips],
    BodyTool.legs => p.bodyOrDefault.legs,
    _ => const [],
  };

  EditParams _withArea(EditParams p, int i, BodyArea a) {
    final body = p.bodyOrDefault;
    return p.copyWith(
      body: switch (widget.tool) {
        BodyTool.hips => body.copyWith(hips: a),
        _ => body.copyWith(legs: [for (final (j, l) in body.legs.indexed) j == i ? a : l]),
      },
    );
  }

  /// Which part of [s] is under [pos]: 0 left bracket, 1 right, 2 the line; null if none.
  int? _slimPart(SlimArea s, Offset pos, Rect rect, BandWarp yWarp, {bool anywhere = false}) {
    final y = rect.top + yWarp.map(s.y) * rect.height;
    final ends = [s.left, s.right].map((x) => Offset(rect.left + x * rect.width, y)).toList();
    final near = (ends[0] - pos).distance <= (ends[1] - pos).distance ? 0 : 1;
    if ((ends[near] - pos).distance < 44) return near;
    if (anywhere) return 2;
    final onLine = (pos.dy - y).abs() < 28 && pos.dx > ends[0].dx - 10 && pos.dx < ends[1].dx + 10;
    return onLine ? 2 : null;
  }

  /// Slim's area moved by a drag of [delta] (screen pixels) on [part].
  SlimArea _dragSlim(SlimArea s, int part, Offset pos, Offset delta, Rect rect, BandWarp yWarp) {
    final y = yWarp.unmap(((pos.dy - rect.top) / rect.height).clamp(0.02, 0.98));
    final x = ((pos.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    switch (part) {
      case 0:
        return s.copyWith(y: y, left: math.min(x, s.right - 0.04));
      case 1:
        return s.copyWith(y: y, right: math.max(x, s.left + 0.04));
      default:
        // Moving the whole line: the brackets jump to the body's edges at the
        // new height when the outline is known, else they just come along.
        final ny = (s.y + delta.dy / rect.height).clamp(0.02, 0.98);
        final dx = delta.dx / rect.width;
        final moved = s.copyWith(y: ny, left: (s.left + dx).clamp(0.0, 1.0), right: (s.right + dx).clamp(0.0, 1.0));
        final edges = delta.dy.abs() > delta.dx.abs() ? widget.mask?.edgesAt(ny, (moved.left + moved.right) / 2) : null;
        return edges != null && edges.$2 - edges.$1 > 0.04 ? moved.copyWith(left: edges.$1, right: edges.$2) : moved;
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
      final rect = fitRect(size, box.biggest, pad: 16, top: widget.top);
      final p = widget.params;
      final yWarp = BandWarp(p.heightBand.$1, p.heightBand.$2, p.height);
      final draft = widget.slimDraft;
      // Slim, after its area is picked: the newest area can be dragged again,
      // and tapping an earlier one's line brings it back to change.
      final active = widget.tool == BodyTool.slim && draft == null && p.slims.isNotEmpty ? p.slims.last : null;
      return GestureDetector(
        onTapUp: active == null
            ? null
            : (d) {
                for (final (i, s) in p.slims.indexed) {
                  if (i == p.slims.length - 1 || _slimPart(s, d.localPosition, rect, yWarp) == null) continue;
                  HapticFeedback.selectionClick();
                  widget.onCommit(p.copyWith(slims: [...p.slims]..removeAt(i)..add(s)));
                  return;
                }
              },
        onPanStart: (d) {
          final pos = d.localPosition;
          _line = _area = _bracket = null;
          _last = pos;
          if (draft != null) {
            _bracket = _slimPart(draft, pos, rect, yWarp, anywhere: true);
          } else if (active != null) {
            _bracket = _slimPart(active, pos, rect, yWarp);
          } else if (widget.tool == BodyTool.stretch) {
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
          if (_line != null || _area != null || (_bracket ?? 2) < 2) HapticFeedback.selectionClick();
        },
        onPanUpdate: (d) {
          final pos = d.localPosition;
          final line = _line, area = _area, bracket = _bracket;
          final delta = pos - (_last ?? pos);
          if (bracket != null && draft != null) {
            widget.onSlimDraft?.call(_dragSlim(draft, bracket, pos, delta, rect, yWarp));
          } else if (bracket != null && active != null) {
            final moved = _dragSlim(active, bracket, pos, delta, rect, yWarp);
            widget.onLive(p.copyWith(slims: [...p.slims.sublist(0, p.slims.length - 1), moved]));
          } else if (line != null) {
            final v = yWarp.unmap(((pos.dy - rect.top) / rect.height).clamp(0.0, 1.0));
            final band = line == 0
                ? (math.min(v, p.heightBand.$2 - 0.05), p.heightBand.$2)
                : (p.heightBand.$1, math.max(v, p.heightBand.$1 + 0.05));
            widget.onLive(p.copyWith(heightBand: band));
          } else if (area != null) {
            final a = _areas(p)[area].moved(delta.dx / rect.width, delta.dy / rect.height);
            widget.onLive(_withArea(p, area, a));
          }
          _last = pos;
        },
        onPanEnd: (_) {
          // A finished drag is one undo step (Slim's area while it's being picked isn't a change yet).
          final changed = _line != null || _area != null || (_bracket != null && draft == null);
          _line = _area = _bracket = null;
          if (changed) widget.onCommit();
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _BodyPainter(
            image: widget.image,
            params: p,
            rect: rect,
            tool: draft != null ? null : widget.tool,
            areas: draft != null ? const [] : _areas(p),
            yWarp: yWarp,
            slimDraft: draft,
            slims: widget.tool == BodyTool.slim && draft == null ? p.slims : const [],
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
    this.slimDraft,
    this.slims = const [],
  });

  final ui.Image image;
  final EditParams params;
  final Rect rect;
  final BodyTool? tool;
  final List<BodyArea> areas;
  final BandWarp yWarp;
  final SlimArea? slimDraft;
  final List<SlimArea> slims; // made already: the last one is being changed, the others can be tapped

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(rect.left, rect.top);
    paintFinish(canvas, image, rect.size, params);
    canvas.restore();

    final draft = slimDraft;
    if (draft != null) {
      _slimLine(canvas, draft);
      return;
    }
    for (final (i, s) in slims.indexed) {
      _slimLine(canvas, s, opacity: i == slims.length - 1 ? 0.9 : 0.4);
    }
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
    } else if (tool == BodyTool.hips || tool == BodyTool.legs) {
      for (final a in areas) {
        final c = Offset(rect.left + a.cx * rect.width, rect.top + yWarp.map(a.cy) * rect.height);
        final r = Rect.fromCenter(center: c, width: a.rx * rect.width * 1.4, height: a.ry * rect.height * 1.6);
        _dashedOval(canvas, r, edge);
        canvas.drawCircle(c, 9, Paint()..color = accent);
        canvas.drawCircle(c, 3.5, Paint()..color = onAccent);
      }
    }
  }

  /// Slim's line, with a dashed bracket at each end curving in towards the
  /// middle ( ")———(" ), white over a soft shadow so it shows on any photo.
  void _slimLine(Canvas canvas, SlimArea s, {double opacity = 1}) {
    final y = rect.top + yWarp.map(s.y) * rect.height;
    final l = rect.left + s.left * rect.width, r = rect.left + s.right * rect.width;
    // The brackets' size follows the line's length, so a narrow pick stays readable.
    final arcR = ((r - l) * 0.3).clamp(12.0, 30.0), inset = arcR * 0.75;
    const sweep = 1.05; // half-angle of each arc
    for (final (colour, width) in [(const Color(0x66000000), 4.5), (Colors.white, 2.5)]) {
      final paint = Paint()
        ..color = colour.withValues(alpha: colour.a * opacity)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(l + 10, y), Offset(r - 10, y), paint);
      for (final (x, side) in [(l, -1.0), (r, 1.0)]) {
        final centre = Offset(x + side * inset, y);
        final start = side < 0 ? -sweep : math.pi - sweep;
        final arc = Path()..addArc(Rect.fromCircle(center: centre, radius: arcR), start, sweep * 2);
        for (final m in arc.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += 9) {
            canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), paint);
          }
        }
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
      old.image != image ||
      old.params != params ||
      old.rect != rect ||
      old.tool != tool ||
      old.slimDraft != slimDraft ||
      old.slims != slims;
}

// --- The panel under the photo -----------------------------------------------------

/// Three states:
/// - no tool open: the row of tools;
/// - Slim picking its area: a big ✓ and "Select the waist area." (as in Cymera);
/// - a tool open: its slider (with the value over the thumb) above the row.
///   Tap the open tool again to close it; Crop and Adjust stay below.
class BodyPanel extends StatelessWidget {
  const BodyPanel({
    super.key,
    required this.params,
    required this.tool,
    required this.pose,
    required this.onOpen,
    required this.onLive,
    required this.onCommit,
    this.selecting = false,
    this.onConfirmSlim,
    this.onCancelSlim,
    this.onNewSlim,
  });

  final EditParams params;
  final BodyTool? tool;
  final PoseStatus pose;
  final ValueChanged<BodyTool> onOpen;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;
  final bool selecting; // Slim's area is being picked
  final VoidCallback? onConfirmSlim, onCancelSlim, onNewSlim;

  @override
  Widget build(BuildContext context) {
    final t = tool;
    if (selecting) return _selectStep();
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final b in BodyTool.values)
          _ToolButton(tool: b, selected: b == t, active: b.applied(params), onTap: () => onOpen(b)),
      ],
    );
    if (t == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [_PoseLine(status: pose), const SizedBox(height: 10), row, const SizedBox(height: 12)],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ValueSlider(
          value: t.value(params).clamp(t.twoWay ? -1.0 : 0.0, 1.0),
          twoWay: t.twoWay,
          onChanged: (v) => onLive(t.withValue(params, v)),
          onChangeEnd: () => onCommit(),
        ),
        if (t == BodyTool.slim) _slimActions(),
        const SizedBox(height: 4),
        row,
        const SizedBox(height: 12),
      ],
    );
  }

  /// Under Slim's slider: another area, or take this one away.
  Widget _slimActions() {
    final n = params.slims.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              n <= 1 ? 'Drag The Line Or Its Brackets To Move The Area' : 'Tap Another Line To Change That Area',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600, height: 1.3),
            ),
          ),
          IconButton(
            tooltip: 'Remove This Area',
            visualDensity: VisualDensity.compact,
            onPressed: n == 0 ? null : () => onCommit(params.copyWith(slims: params.slims.sublist(0, n - 1))),
            icon: Icon(Icons.delete_outline_rounded, size: 20, color: muted),
          ),
          TextButton.icon(
            onPressed: onNewSlim,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New Area'),
          ),
        ],
      ),
    );
  }

  Widget _selectStep() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            TextButton(onPressed: onCancelSlim, child: Text('Cancel', style: TextStyle(color: muted))),
            const Spacer(),
            _ConfirmButton(onTap: onConfirmSlim),
            const Spacer(),
            const SizedBox(width: 72),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          pose == PoseStatus.found ? 'Select the waist area.' : 'Select the waist area: drag the line onto the body.',
          style: TextStyle(fontSize: 13, color: muted, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// The round ✓ that confirms Slim's area.
class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: accent,
    shape: const CircleBorder(),
    elevation: 2,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onTap!();
            },
      child: const SizedBox(width: 64, height: 64, child: Icon(Icons.check_rounded, size: 34, color: onAccent)),
    ),
  );
}

/// "−  ———●———  +" with the value in a bubble over the thumb ("+0.55").
/// Two-way sliders centre on 0, which is sticky so "untouched" is easy to find.
class _ValueSlider extends StatelessWidget {
  const _ValueSlider({required this.value, required this.twoWay, required this.onChanged, required this.onChangeEnd});
  final double value;
  final bool twoWay;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;

  static const _pad = 14.0; // the slider's own inset at each end of the track

  @override
  Widget build(BuildContext context) {
    final min = twoWay ? -1.0 : 0.0;
    final text = value > 0.005 ? '+${value.toStringAsFixed(2)}' : value.toStringAsFixed(2).replaceAll('-0.00', '0.00');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Icon(Icons.remove_rounded, size: 20, color: muted)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final x = _pad + (value - min) / (1 - min) * (box.maxWidth - _pad * 2);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 30),
                      child: Slider(
                        value: value,
                        min: min,
                        padding: const EdgeInsets.symmetric(horizontal: _pad),
                        onChanged: (v) {
                          if (twoWay && v.abs() < 0.04) {
                            if (value != 0) HapticFeedback.selectionClick();
                            v = 0;
                          }
                          onChanged(v);
                        },
                        onChangeStart: (_) => HapticFeedback.selectionClick(),
                        onChangeEnd: (_) => onChangeEnd(),
                      ),
                    ),
                    Positioned(
                      left: (x - 28).clamp(0.0, math.max(0.0, box.maxWidth - 56)),
                      top: 0,
                      width: 56,
                      child: Container(
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: surfaceHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: value.abs() > 0.005 ? accent : line),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: value.abs() > 0.005 ? accent : muted,
                            fontFeatures: const [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Icon(Icons.add_rounded, size: 20, color: muted)),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.tool, required this.selected, required this.active, required this.onTap});
  final BodyTool tool;
  final bool selected; // the tool that's open
  final bool active; // already applied to this photo
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = selected ? accent : ink;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(size: const Size(52, 52), painter: _ToolIcon(tool, colour)),
                if (active)
                  Positioned(
                    right: -4,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(tool.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colour)),
          ],
        ),
      ),
    );
  }
}

class _PoseLine extends StatelessWidget {
  const _PoseLine({required this.status});
  final PoseStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (status) {
      PoseStatus.detecting => (null, 'Finding The Body…', muted),
      PoseStatus.found => (Icons.person_search_rounded, 'Body Found: The Tools Know Where To Work', positive),
      PoseStatus.notFound => (Icons.touch_app_rounded, 'No Person Found: You\'ll Place Each Tool By Hand', muted),
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
        // Waist curving out into hips.
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
        canvas.drawCircle(const Offset(26, 22), 1.2, p);
      case BodyTool.legs:
        // A leg in profile, with sparkles.
        canvas.drawPath(
          Path()
            ..moveTo(22, 4)
            ..cubicTo(26, 16, 20, 26, 24, 36)
            ..cubicTo(26, 42, 22, 46, 30, 47),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(32, 4)
            ..cubicTo(34, 16, 30, 26, 32, 36)
            ..cubicTo(33, 42, 34, 44, 40, 47),
          p,
        );
        for (final c in [const Offset(12, 14), const Offset(44, 26)]) {
          canvas.drawLine(c - const Offset(4, 0), c + const Offset(4, 0), p);
          canvas.drawLine(c - const Offset(0, 4), c + const Offset(0, 4), p);
        }
    }
  }

  @override
  bool shouldRepaint(_ToolIcon old) => old.tool != tool || old.color != color;
}
