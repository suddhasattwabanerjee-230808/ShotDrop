import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'card_channel.dart';
import 'models.dart';
import 'stores.dart';
import 'update.dart';
import 'theme.dart';

/// The app's stores (and its updater), reachable from any screen.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.card,
    required this.phone,
    required this.uploads,
    required this.social,
    required this.updater,
    required this.settings,
    required super.child,
  });

  final CardStore card;
  final PhoneStore phone;
  final UploadStore uploads;
  final SocialSettings social;
  final Updater updater;
  final AppSettings settings;

  static AppScope of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      card != oldWidget.card ||
      phone != oldWidget.phone ||
      uploads != oldWidget.uploads ||
      social != oldWidget.social ||
      updater != oldWidget.updater ||
      settings != oldWidget.settings;
}

/// Card thumbnails asked for once per session; later requests reuse the answer.
class ThumbCache {
  static final _paths = <String, Future<String?>>{};
  static final _made = <String, String>{}; // finished answers
  static final _gone = <String, String>{}; // answers from before the files were cleared

  /// Forgets every answer (after the files were cleared from storage). The
  /// pictures still held in memory keep showing without going back to the card.
  static void clear() {
    _gone.addAll(_made);
    _made.clear();
    _paths.clear();
  }

  static String _key(CardFile file, int maxEdge, bool fast) => '${file.docId}|${file.modified}|$maxEdge|$fast';

  /// The thumbnail's path if it's already made (no waiting), else null.
  static String? ready(CardFile file, {required int maxEdge, bool fast = false}) => _made[_key(file, maxEdge, fast)];

  /// Forgets [file]'s thumbnails: their files went, and memory doesn't hold them either.
  static void forget(CardFile file, {required int maxEdge}) {
    for (final key in [_key(file, maxEdge, false), _key(file, 160, true)]) {
      _paths.remove(key);
      _made.remove(key);
      _gone.remove(key);
    }
  }

  static Future<String?> get(CardFile file, {required int maxEdge, bool fast = false}) {
    final key = _key(file, maxEdge, fast);
    return _paths.putIfAbsent(key, () {
      // Cleared from storage but still decoded in memory: show that, no card read.
      final old = _gone.remove(key);
      if (old != null && PaintingBinding.instance.imageCache.containsKey(FileImage(File(old)))) {
        _made[key] = old;
        return Future.value(old);
      }
      final f = CardChannel.instance.thumbnail(file, maxEdge: maxEdge, fast: fast).then((p) {
        if (p != null) _made[key] = p;
        return p;
      });
      // A failure (card pulled mid-read) shouldn't stick: forget it so the next ask retries.
      return f.catchError((Object _) {
        _paths.remove(key);
        return null;
      });
    });
  }
}

/// A card photo that shows the camera's tiny built-in preview at once, then
/// swaps in a sharp one at [maxEdge] when it's ready.
class CardImage extends StatefulWidget {
  const CardImage({super.key, required this.file, required this.maxEdge, this.fit = BoxFit.cover});

  final CardFile file;
  final int maxEdge;
  final BoxFit fit;

  @override
  State<CardImage> createState() => _CardImageState();
}

class _CardImageState extends State<CardImage> {
  String? _fast, _sharp;
  bool _retried = false;

  // The file went (thumbnails are cleared when ShotDrop goes to the background): make it again, once.
  void _retry() {
    if (_retried) return;
    _retried = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ThumbCache.forget(widget.file, maxEdge: widget.maxEdge);
      setState(() => _fast = _sharp = null);
      _load();
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CardImage old) {
    super.didUpdateWidget(old);
    if (old.file.docId != widget.file.docId || old.maxEdge != widget.maxEdge) {
      _fast = _sharp = null;
      _retried = false;
      _load();
    }
  }

  void _load() {
    final file = widget.file;
    // Already made: straight in, no blank frame.
    _sharp = ThumbCache.ready(file, maxEdge: widget.maxEdge);
    if (_sharp != null) return;
    _fast = ThumbCache.ready(file, maxEdge: 160, fast: true);
    // The camera's preview first, then the sharp one: asked in turn, as the card
    // reads the newest request first.
    ThumbCache.get(file, maxEdge: 160, fast: true).then((p) {
      if (mounted && file.docId == widget.file.docId && _sharp == null) setState(() => _fast = p);
      if (!mounted || file.docId != widget.file.docId) return;
      ThumbCache.get(file, maxEdge: widget.maxEdge).then((p) {
        if (mounted && file.docId == widget.file.docId) setState(() => _sharp = p);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _sharp ?? _fast;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: path == null
          ? ColoredBox(key: const ValueKey('empty'), color: surface, child: const SizedBox.expand())
          : Image.file(
              File(path),
              key: ValueKey(path),
              fit: widget.fit,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) {
                _retry();
                return ColoredBox(color: surface, child: const SizedBox.expand());
              },
            ),
    );
  }
}

/// A small rounded label laid over a photo ("RAW", "In Upload").
class PhotoBadge extends StatelessWidget {
  // Over a photo, so light text in either mode.
  const PhotoBadge({
    super.key,
    required this.label,
    this.icon,
    this.color = const Color(0xB32D1E4F),
    this.fg = const Color(0xFFFFFFFF),
  });

  final String label;
  final IconData? icon;
  final Color color, fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x55FFFFFF), width: 1.2),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 3)],
        Text(
          label,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg, letterSpacing: 0.5),
        ),
      ],
    ),
  );
}

/// Big centred icon + text, for empty and waiting states.
class StatePanel extends StatelessWidget {
  const StatePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
    this.iconWidget,
  });

  final IconData icon;
  final Widget? iconWidget;
  final String title, body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget ?? FunIcon(icon: icon),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.15),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15.5, color: muted, height: 1.45),
          ),
          if (actions.isNotEmpty) const SizedBox(height: 28),
          for (final a in actions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(width: 280, child: a),
            ),
        ],
      ),
    ),
  );
}

/// A big icon on a bouncy candy blob, gently bobbing: the picture on empty
/// and waiting screens.
class FunIcon extends StatefulWidget {
  const FunIcon({super.key, required this.icon, this.colors, this.size = 104});
  final IconData icon;
  final List<Color>? colors; // the blob's gradient (default: pink to tangerine)
  final double size;

  @override
  State<FunIcon> createState() => _FunIconState();
}

class _FunIconState extends State<FunIcon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors ?? [accent, tangerine];
    final s = widget.size;
    return SizedBox(
      width: s * 1.5,
      height: s * 1.35,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = Curves.easeInOutSine.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              // Sparkles around the blob, twinkling out of step with the bob.
              for (final (dx, dy, size, colour, phase) in [
                (-0.62, -0.42, 16.0, sunny, 0.0),
                (0.64, -0.3, 11.0, sky, 0.5),
                (0.58, 0.5, 14.0, grass, 0.25),
                (-0.6, 0.46, 9.0, grape, 0.75),
              ])
                Align(
                  alignment: Alignment(dx, dy),
                  child: Transform.scale(
                    scale: 0.7 + 0.3 * ((t + phase) % 1),
                    child: CustomPaint(size: Size.square(size), painter: _SparklePainter(colour)),
                  ),
                ),
              Transform.translate(
                offset: Offset(0, -5 + 10 * t),
                child: Transform.rotate(angle: -0.06 + 0.12 * t, child: child),
              ),
            ],
          );
        },
        child: Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            borderRadius: BorderRadius.circular(s * 0.36),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 3),
            boxShadow: [BoxShadow(color: deeper(colors.last, 0.2), offset: const Offset(0, 6))],
          ),
          child: Icon(widget.icon, size: s * 0.46, color: Colors.white),
        ),
      ),
    );
  }
}

/// A four-pointed twinkle.
class _SparklePainter extends CustomPainter {
  const _SparklePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawPath(sparklePath(size.center(Offset.zero), size.width / 2), Paint()..color = color);

  @override
  bool shouldRepaint(_SparklePainter old) => old.color != color;
}

/// A four-pointed star of radius [r] around [c].
Path sparklePath(Offset c, double r) {
  final k = r * 0.22;
  return Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx + k, c.dy - k, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + k, c.dy + k, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - k, c.dy + k, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - k, c.dy - k, c.dx, c.dy - r)
    ..close();
}

/// The page background behind the tabs: cream (or night) paper with soft
/// colour blobs and a sprinkle of confetti. Paints under [child], which keeps
/// its own Scaffold see-through.
class PlayBackdrop extends StatelessWidget {
  const PlayBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BackdropPainter(paper: paper, colors: rainbow, light: isLight),
    child: child,
  );
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({required this.paper, required this.colors, required this.light});
  final Color paper;
  final List<Color> colors;
  final bool light;

  // Where the confetti goes, as fractions of the screen: the same every time.
  static final _bits = () {
    final rnd = math.Random(11);
    return [
      for (var i = 0; i < 30; i++)
        (
          x: rnd.nextDouble(),
          y: rnd.nextDouble(),
          kind: rnd.nextInt(4),
          size: 0.6 + rnd.nextDouble() * 0.6,
          turn: rnd.nextDouble() * math.pi,
        ),
    ];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    canvas.drawRect(screen, Paint()..color = paper);
    // Big soft blobs.
    final glow = light ? 0.20 : 0.24;
    for (final (fx, fy, fr, ci) in [
      (1.0, 0.04, 0.62, 0),
      (-0.05, 0.45, 0.55, 4),
      (0.95, 0.88, 0.6, 3),
      (0.1, 1.0, 0.4, 1),
    ]) {
      final c = Offset(size.width * fx, size.height * fy);
      final r = size.width * fr;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colors[ci].withValues(alpha: glow),
              colors[ci].withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    // Confetti.
    final alpha = light ? 0.5 : 0.45;
    for (final (i, b) in _bits.indexed) {
      final c = Offset(b.x * size.width, b.y * size.height);
      final paint = Paint()..color = colors[i % colors.length].withValues(alpha: alpha);
      final s = 6 * b.size;
      switch (b.kind) {
        case 0:
          canvas.drawCircle(c, s * 0.7, paint);
        case 1:
          canvas.drawCircle(
            c,
            s,
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5,
          );
        case 2:
          canvas.drawPath(sparklePath(c, s * 1.5), paint);
        default:
          // A little squiggle.
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(b.turn);
          final w = Path()..moveTo(-s * 2, 0);
          for (var k = 0; k < 4; k++) {
            w.relativeQuadraticBezierTo(s * 0.5, (k.isEven ? -1 : 1) * s, s, 0);
          }
          canvas.drawPath(
            w,
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..strokeCap = StrokeCap.round,
          );
          canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.paper != paper || old.light != light || !listEquals(old.colors, colors);
}

String shortDay(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final base = '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

String clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String fileSize(int bytes) =>
    bytes >= 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';

/// The Instagram logo (the camera glyph on its gradient), drawn so it needs
/// no image file: marks the Instagram account in Settings.
class InstagramLogo extends StatelessWidget {
  const InstagramLogo({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _InstagramLogoPainter());
}

class _InstagramLogoPainter extends CustomPainter {
  const _InstagramLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final box = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(s * 0.28)),
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.7, 1.1),
          radius: 1.5,
          colors: [Color(0xFFFFD522), Color(0xFFF1570C), Color(0xFFD72F7C), Color(0xFF9B2BB5), Color(0xFF5A4FCF)],
          stops: [0, 0.3, 0.55, 0.8, 1],
        ).createShader(box),
    );
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.2, s * 0.2, s * 0.6, s * 0.6), Radius.circular(s * 0.18)),
      white,
    );
    canvas.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.14, white);
    canvas.drawCircle(Offset(s * 0.665, s * 0.335), s * 0.045, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_InstagramLogoPainter old) => false;
}

/// Facebook's mark: a white "f" on its blue circle, its stem running off the bottom.
class FacebookLogo extends StatelessWidget {
  const FacebookLogo({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _FacebookLogoPainter());
}

class _FacebookLogoPainter extends CustomPainter {
  const _FacebookLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    final circle = Path()..addOval(Offset.zero & size);
    canvas.drawPath(circle, Paint()..color = const Color(0xFF1877F2));
    // The "f", drawn on a 100 x 100 grid.
    final f = Path()
      ..moveTo(42, 100)
      ..lineTo(42, 63)
      ..lineTo(31, 63)
      ..lineTo(31, 50)
      ..lineTo(42, 50)
      ..lineTo(42, 40)
      ..cubicTo(42, 28, 50, 21, 62, 21)
      ..lineTo(70, 21)
      ..lineTo(70, 33)
      ..lineTo(63, 33)
      ..cubicTo(58, 33, 57, 36, 57, 40)
      ..lineTo(57, 50)
      ..lineTo(69, 50)
      ..lineTo(67, 63)
      ..lineTo(57, 63)
      ..lineTo(57, 100)
      ..close();
    canvas.save();
    canvas.clipPath(circle);
    canvas.scale(k);
    canvas.drawPath(f, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FacebookLogoPainter old) => false;
}

/// Instagram's logo with Facebook's tucked into its corner: a post that goes
/// to both.
class InstagramFacebookLogo extends StatelessWidget {
  const InstagramFacebookLogo({super.key, this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.3,
    height: size * 1.3,
    child: Stack(
      children: [
        InstagramLogo(size: size),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.all(size * 0.06),
            decoration: BoxDecoration(color: surface, shape: BoxShape.circle),
            child: FacebookLogo(size: size * 0.55),
          ),
        ),
      ],
    ),
  );
}
