import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_screen.dart';

Future<void> openViewer(BuildContext context, List<CardShot> shots, int index) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => ViewerScreen(shots: shots, initialIndex: index),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ),
);

/// Full-screen photos from the card: swipe through them, pinch to zoom, and
/// send the one on screen to the editor. After editing it comes back here, on
/// the same photo, ready for a swipe to the next one.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.shots, required this.initialIndex});

  final List<CardShot> shots;
  final int initialIndex;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;
  bool _chrome = true;

  CardShot get _shot => widget.shots[_index];

  @override
  void initState() {
    super.initState();
    _prefetch(_index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Start reading the neighbours so a swipe lands on a sharp photo.
  void _prefetch(int i) {
    for (final j in [i + 1, i - 1, i + 2]) {
      if (j >= 0 && j < widget.shots.length) ThumbCache.get(widget.shots[j].primary, maxEdge: _viewerEdge);
    }
  }

  Future<void> _edit() async {
    final shot = _shot;
    if (!shot.editable) return;
    final uploads = AppScope.of(context).uploads;
    final existing = uploads.byShot(shot.id);
    final saved = await openEditor(context, [
      existing != null && !existing.published
          ? EditTarget.fromItem(existing, card: shot.jpg)
          : EditTarget.fromShot(shot),
    ]);
    if (!mounted || saved == 0) return;
    final hasNext = _index < widget.shots.length - 1;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Added to the Upload folder'),
        duration: const Duration(seconds: 3),
        persist: false, // with a button it would otherwise stay until tapped
        action: hasNext
            ? SnackBarAction(
                label: 'Next photo',
                onPressed: () =>
                    _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
            itemCount: widget.shots.length,
            onPageChanged: (i) {
              setState(() {
                _index = i;
                _zoomed = false;
              });
              _prefetch(i);
            },
            itemBuilder: (context, i) => _ZoomablePhoto(
              shot: widget.shots[i],
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              onTap: () => setState(() => _chrome = !_chrome),
            ),
          ),
          // Top bar
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_chrome,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xCC000000), Color(0x00000000)],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 16, 24),
                      child: Row(
                        children: [
                          const BackButton(color: Colors.white),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_shot.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                                Text(
                                  '${shortDay(_shot.taken)} · ${clock(_shot.taken)} · ${fileSize(_shot.primary.size)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xCCFFFFFF),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '${_index + 1} / ${widget.shots.length}',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xCCFFFFFF)),
                          ),
                          const SizedBox(width: 4),
                          _HeartButton(shot: _shot),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Bottom bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedSlide(
              offset: _chrome ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xE6000000), Color(0x00000000)],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 32, 16, 12),
                    child: ListenableBuilder(
                      listenable: uploads,
                      builder: (context, _) {
                        final queued = uploads.contains(_shot.id);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_shot.jpg != null) const PhotoBadge(label: 'JPG'),
                                if (_shot.hasRaw) ...[const SizedBox(width: 6), const PhotoBadge(label: 'NEF')],
                                if (queued) ...[
                                  const SizedBox(width: 6),
                                  const PhotoBadge(
                                    label: 'IN UPLOAD FOLDER',
                                    icon: Icons.check_rounded,
                                    color: positive,
                                    fg: Color(0xFF06210F),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: _shot.editable
                                  ? FilledButton.icon(
                                      onPressed: _edit,
                                      icon: Icon(queued ? Icons.tune_rounded : Icons.auto_fix_high_rounded),
                                      label: Text(queued ? 'Edit again' : 'Edit before upload'),
                                    )
                                  : const OutlinedButton(onPressed: null, child: Text('RAW only: can\'t be edited')),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _viewerEdge = 2048;

class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({required this.shot, required this.onZoomChanged, required this.onTap});

  final CardShot shot;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> with SingleTickerProviderStateMixin {
  final _t = TransformationController();
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomTo;
  TapDownDetails? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    _t.addListener(() => widget.onZoomChanged(_t.value.getMaxScaleOnAxis() > 1.01));
    _anim.addListener(() {
      final z = _zoomTo;
      if (z != null) _t.value = z.value;
    });
  }

  @override
  void dispose() {
    _t.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final zoomed = _t.value.getMaxScaleOnAxis() > 1.01;
    final p = _doubleTapAt?.localPosition ?? Offset.zero;
    final end = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
            ..scaleByDouble(2.5, 2.5, 1, 1));
    _zoomTo = Matrix4Tween(
      begin: _t.value,
      end: end,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onDoubleTapDown: (d) => _doubleTapAt = d,
    onDoubleTap: _toggleZoom,
    child: InteractiveViewer(
      transformationController: _t,
      minScale: 1,
      maxScale: 5,
      child: Hero(
        tag: 'shot-${widget.shot.id}',
        child: CardImage(file: widget.shot.primary, maxEdge: _viewerEdge, fit: BoxFit.contain),
      ),
    ),
  );
}

/// ♡ on the photo on screen: keeps it in Selected (copied off the card) to
/// edit and post later; tap again to take it out.
class _HeartButton extends StatelessWidget {
  const _HeartButton({required this.shot});
  final CardShot shot;

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return ListenableBuilder(
      listenable: uploads,
      builder: (context, _) {
        final kept = uploads.isSelected(shot.id), queued = uploads.contains(shot.id);
        return IconButton(
          tooltip: kept ? 'Remove from Selected' : 'Add to Selected',
          onPressed: shot.jpg == null
              ? null
              : () async {
                  HapticFeedback.lightImpact();
                  final messenger = ScaffoldMessenger.of(context);
                  if (queued) {
                    messenger.showSnackBar(
                      const SnackBar(duration: Duration(seconds: 3), content: Text('It\'s in the Upload folder already')),
                    );
                  } else if (kept) {
                    final item = await uploads.remove(shot.id);
                    if (item != null && !item.edited) uploads.purge(item);
                  } else {
                    await uploads.select([shot]);
                  }
                },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.elasticOut), child: c),
            child: Icon(
              kept || queued ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(kept || queued),
              color: kept || queued ? accent : Colors.white,
              size: 26,
            ),
          ),
        );
      },
    );
  }
}
