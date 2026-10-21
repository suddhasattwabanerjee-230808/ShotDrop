import 'dart:io';

import 'package:flutter/material.dart';

import 'card_channel.dart';
import 'models.dart';
import 'stores.dart';
import 'theme.dart';

/// The app's two stores, reachable from any screen.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.card, required this.uploads, required super.child});

  final CardStore card;
  final UploadStore uploads;

  static AppScope of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) => card != oldWidget.card || uploads != oldWidget.uploads;
}

/// Card thumbnails asked for once per session; later requests reuse the answer.
class ThumbCache {
  static final _paths = <String, Future<String?>>{};

  static Future<String?> get(CardFile file, {required int maxEdge, bool fast = false}) {
    final key = '${file.docId}|${file.modified}|$maxEdge|$fast';
    return _paths.putIfAbsent(key, () {
      final f = CardChannel.instance.thumbnail(file, maxEdge: maxEdge, fast: fast);
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
      _load();
    }
  }

  void _load() {
    final file = widget.file;
    ThumbCache.get(file, maxEdge: 160, fast: true).then((p) {
      if (mounted && file.docId == widget.file.docId && _sharp == null) setState(() => _fast = p);
    });
    ThumbCache.get(file, maxEdge: widget.maxEdge).then((p) {
      if (mounted && file.docId == widget.file.docId) setState(() => _sharp = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _sharp ?? _fast;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: path == null
          ? const ColoredBox(key: ValueKey('empty'), color: surface, child: SizedBox.expand())
          : Image.file(
              File(path),
              key: ValueKey(path),
              fit: widget.fit,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const ColoredBox(color: surface, child: SizedBox.expand()),
            ),
    );
  }
}

/// A small rounded label laid over a photo ("RAW", "In Upload").
class PhotoBadge extends StatelessWidget {
  const PhotoBadge({super.key, required this.label, this.icon, this.color = const Color(0xB3000000), this.fg = ink});

  final String label;
  final IconData? icon;
  final Color color, fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 11, color: fg), const SizedBox(width: 3)],
        Text(
          label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg, letterSpacing: 0.4),
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
          iconWidget ??
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: line),
                ),
                child: Icon(icon, size: 42, color: accent),
              ),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1.2),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: muted, height: 1.45),
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
