import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'widgets.dart';

/// Rebuilds every widget in the app, so each one picks up the palette's new
/// colours (they're plain getters, read in build, not looked up in a Theme).
/// Screens keep their state: an edit in progress, a scroll position, an open sheet.
void rebuildAll() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}

/// Sits over the whole app (MaterialApp.builder) and switches between light
/// and dark: a picture of the screen as it was stays on top while the new
/// colours spread out from the button in a growing circle.
class ThemeFlip extends StatefulWidget {
  const ThemeFlip({super.key, required this.child});
  final Widget child;

  /// Switches mode, revealing the new one from [from] (a point on screen).
  static void toggle(BuildContext context, Offset from) =>
      context.findAncestorStateOfType<_ThemeFlipState>()?._toggle(from);

  @override
  State<ThemeFlip> createState() => _ThemeFlipState();
}

class _ThemeFlipState extends State<ThemeFlip> with SingleTickerProviderStateMixin {
  final _shotKey = GlobalKey();
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 560))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _dropShot();
    });
  ui.Image? _shot; // the screen before the switch
  Offset _from = Offset.zero;
  bool _busy = false;

  @override
  void dispose() {
    _reveal.dispose();
    _shot?.dispose();
    super.dispose();
  }

  void _dropShot() {
    if (!mounted) return;
    final shot = _shot;
    setState(() => _shot = null);
    // After the frame that stops drawing it.
    WidgetsBinding.instance.addPostFrameCallback((_) => shot?.dispose());
  }

  Future<void> _toggle(Offset from) async {
    if (_busy) return;
    _busy = true;
    HapticFeedback.lightImpact();
    ui.Image? shot;
    try {
      final boundary = _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      shot = await boundary?.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
    } catch (_) {
      shot = null; // no picture, no reveal: the colours just change
    }
    if (!mounted) {
      shot?.dispose();
      _busy = false;
      return;
    }
    final light = !isLight;
    usePalette(light: light);
    AppScope.of(context).settings.set(lightMode: light).ignore();
    rebuildAll();
    _shot?.dispose();
    setState(() {
      _shot = shot;
      _from = from;
    });
    if (shot != null) await _reveal.forward(from: 0).orCancel.catchError((Object _) {});
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final shot = _shot;
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      children: [
        RepaintBoundary(key: _shotKey, child: widget.child),
        if (shot != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _reveal,
                builder: (context, _) =>
                    CustomPaint(painter: _RevealPainter(shot, _from, Curves.easeInOutCubic.transform(_reveal.value))),
              ),
            ),
          ),
      ],
    );
  }
}

/// The old screen, with a hole growing out of [from] to show the new one.
class _RevealPainter extends CustomPainter {
  _RevealPainter(this.shot, this.from, this.t);
  final ui.Image shot;
  final Offset from;
  final double t; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    // Far enough to reach the furthest corner.
    final reach = [
      screen.topLeft,
      screen.topRight,
      screen.bottomLeft,
      screen.bottomRight,
    ].map((c) => (c - from).distance).reduce(math.max);
    final hole = Path()..addOval(Rect.fromCircle(center: from, radius: reach * t));
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(screen), hole));
    canvas.drawImageRect(
      shot,
      Offset.zero & Size(shot.width.toDouble(), shot.height.toDouble()),
      screen,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RevealPainter old) => old.shot != shot || old.from != from || old.t != t;
}

/// The light / dark switch on every screen: a sun on a yellow bubble in dark
/// mode, a moon on a purple one in light, spinning as it changes.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key, this.color});

  /// The icon's colour, where the bar isn't the usual one (default: a bubble).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bubble = isLight ? grape : sunny;
    return IconButton(
      tooltip: isLight ? 'Dark Mode' : 'Light Mode',
      color: color,
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        final centre = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
        ThemeFlip.toggle(context, centre);
      },
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 520),
        switchInCurve: Curves.elasticOut,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, a) => RotationTransition(
          turns: Tween(begin: -0.5, end: 0.0).animate(a),
          child: ScaleTransition(
            scale: a,
            child: FadeTransition(opacity: a, child: child),
          ),
        ),
        child: color != null
            ? Icon(isLight ? Icons.dark_mode_rounded : Icons.light_mode_rounded, key: ValueKey(isLight))
            : Container(
                key: ValueKey(isLight),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: bubble,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: deeper(bubble, 0.18), offset: const Offset(0, 3))],
                ),
                child: Icon(
                  isLight ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  size: 21,
                  color: onFun(bubble),
                ),
              ),
      ),
    );
  }
}
