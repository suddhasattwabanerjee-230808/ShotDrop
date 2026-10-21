import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../card_channel.dart';
import '../edit/crop.dart';
import '../edit/filters.dart';
import '../edit/render.dart';
import '../edit/reshape.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

/// A photo to edit: straight from the card, or one already in the Upload folder.
class EditTarget {
  const EditTarget({required this.shotId, required this.name, required this.taken, this.card, this.existing});

  factory EditTarget.fromShot(CardShot s) => EditTarget(shotId: s.id, name: s.name, taken: s.taken, card: s.jpg);

  factory EditTarget.fromItem(UploadItem i, {CardFile? card}) =>
      EditTarget(shotId: i.shotId, name: i.name, taken: i.taken, card: card, existing: i);

  final String shotId, name;
  final DateTime taken;
  final CardFile? card;
  final UploadItem? existing;
}

/// Edits [targets] one after another. Returns how many went into the Upload folder.
Future<int> openEditor(BuildContext context, List<EditTarget> targets) async {
  if (targets.isEmpty) return 0;
  final saved = await Navigator.of(context)
      .push<int>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => EditorScreen(targets: targets)));
  return saved ?? 0;
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.targets});
  final List<EditTarget> targets;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

enum _Tool { crop, body, adjust }

class _EditorScreenState extends State<EditorScreen> {
  int _index = 0;
  int _saved = 0;

  String? _status = 'Opening…'; // non-null while loading or saving
  String? _error;
  String? _sourcePath;
  ui.Image? _preview; // the source, at most _previewEdge px

  EditParams _p = const EditParams();
  final _history = <EditParams>[];
  int _h = -1;

  _Tool _tool = _Tool.crop;
  bool _comparing = false;

  // The cropped preview the Body and Adjust tools draw on; rebuilt when the crop changes.
  ui.Image? _cropped;
  String? _croppedFor;

  static const _previewEdge = 1600;

  EditTarget get _target => widget.targets[_index];
  bool get _dirty => _h > 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _preview?.dispose();
    _cropped?.dispose();
    super.dispose();
  }

  // --- Loading and saving -----------------------------------------------------

  Future<void> _open() async {
    final target = _target;
    final uploads = AppScope.of(context).uploads;
    setState(() {
      _status = 'Opening…';
      _error = null;
      _tool = _Tool.crop;
    });
    try {
      final path = target.existing?.sourcePath ?? await uploads.sourcePathFor(target.shotId);
      if (!await File(path).exists()) {
        final card = target.card;
        if (card == null) throw 'The original isn\'t on the phone any more, and the card isn\'t plugged in.';
        setState(() => _status = 'Copying from the card…');
        await CardChannel.instance.importSource(card, path);
      }
      final image = await _decode(path, maxEdge: _previewEdge);
      if (!mounted || target != _target) return image.dispose();
      final o = Size(image.width.toDouble(), image.height.toDouble());
      final params = target.existing?.params ?? _defaultsFor(o);
      setState(() {
        _preview?.dispose();
        _preview = image;
        _sourcePath = path;
        _p = params;
        _history
          ..clear()
          ..add(params);
        _h = 0;
        _status = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Portrait shots are taller than Instagram allows (2:3 vs 4:5), so they start at 4:5.
  static EditParams _defaultsFor(Size photo) {
    if (photo.width / photo.height < 0.8) {
      return EditParams(aspect: AspectPreset.portrait, crop: centeredCrop(photo, 0.8));
    }
    return const EditParams();
  }

  static Future<ui.Image> _decode(String path, {int? maxEdge}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    int? w, h;
    if (maxEdge != null && math.max(descriptor.width, descriptor.height) > maxEdge) {
      if (descriptor.width >= descriptor.height) {
        w = maxEdge;
      } else {
        h = maxEdge;
      }
    }
    final codec = await descriptor.instantiateCodec(targetWidth: w, targetHeight: h);
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  Future<void> _done() async {
    final source = _sourcePath;
    if (source == null || _status != null) return;
    final target = _target;
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _status = 'Saving to the Upload folder…');
    try {
      final full = await _decode(source);
      final out = await renderFinal(full, _p);
      full.dispose();
      final bytes = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      final exportPath = await uploads.exportPathFor(target.shotId);
      await CardChannel.instance.encodeJpeg(bytes!.buffer.asUint8List(), out.width, out.height, exportPath);
      final (width, height) = (out.width, out.height);
      out.dispose();

      String? galleryUri;
      try {
        galleryUri = await CardChannel.instance.saveToGallery(exportPath, '${target.name}_edit');
        final old = target.existing?.galleryUri;
        if (old != null) CardChannel.instance.deleteFromGallery(old).catchError((Object _) {});
      } catch (_) {
        // The gallery copy is a convenience; the Upload folder works without it.
      }
      await uploads.put(
        UploadItem(
          shotId: target.shotId,
          name: target.name,
          taken: target.taken,
          sourcePath: source,
          exportPath: exportPath,
          params: _p,
          galleryUri: galleryUri,
          width: width,
          height: height,
        ),
      );
      _saved++;
      HapticFeedback.mediumImpact();
      _next();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = null);
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save this photo: $e')));
    }
  }

  void _next() {
    if (!mounted) return;
    if (_index >= widget.targets.length - 1) {
      Navigator.of(context).pop(_saved);
      return;
    }
    setState(() {
      _index++;
      _cropped?.dispose();
      _cropped = null;
      _croppedFor = null;
    });
    _open();
  }

  Future<void> _close() async {
    if (_dirty && _status == null) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this edit?'),
          content: const Text('The changes to this photo won\'t be saved.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
          ],
        ),
      );
      if (leave != true) return;
    }
    if (mounted) Navigator.of(context).pop(_saved);
  }

  // --- Edit history -------------------------------------------------------------

  /// Shows [p] without adding an undo step (while a finger is still moving).
  void _live(EditParams p) => setState(() => _p = p);

  /// Shows [p] and makes it an undo step.
  void _commit([EditParams? p]) {
    final next = p ?? _p;
    setState(() {
      _p = next;
      if (_h >= 0 && identical(_history[_h], next)) return;
      _history.removeRange(_h + 1, _history.length);
      _history.add(next);
      _h = _history.length - 1;
    });
  }

  void _undo() {
    if (_h > 0) setState(() => _p = _history[--_h]);
  }

  void _redo() {
    if (_h < _history.length - 1) setState(() => _p = _history[++_h]);
  }

  // --- Cropped preview for the Body and Adjust tools ------------------------------

  String _cropKey(EditParams p) => '${p.quarterTurns}|${p.flipH}|${p.straighten}|${p.crop}';

  void _ensureCropped() {
    final src = _preview;
    if (src == null || _tool == _Tool.crop) return;
    final key = _cropKey(_p);
    if (key == _croppedFor) return;
    _croppedFor = key;
    renderCropped(src, _p, maxEdge: _previewEdge).then((img) {
      if (!mounted || _croppedFor != key) return img.dispose();
      setState(() {
        _cropped?.dispose();
        _cropped = img;
      });
    });
  }

  // --- Build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _ensureCropped();
    final multi = widget.targets.length > 1;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: _close),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_target.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              Text(
                multi ? 'Photo ${_index + 1} of ${widget.targets.length}' : 'Edit before upload',
                style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          actions: [
            if (multi)
              TextButton(
                onPressed: _status == null ? _next : null,
                child: const Text('Skip', style: TextStyle(color: muted)),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                onPressed: _status == null && _sourcePath != null ? _done : null,
                child: const Text('Done'),
              ),
            ),
          ],
        ),
        body: _error != null
            ? StatePanel(
                icon: Icons.broken_image_outlined,
                title: 'Couldn\'t open this photo',
                body: _error!,
                actions: [
                  FilledButton(onPressed: _open, child: const Text('Try again')),
                  if (multi) TextButton(onPressed: _next, child: const Text('Skip it')),
                ],
              )
            : Column(
                children: [
                  Expanded(child: _stage()),
                  if (_preview != null) _panel(),
                ],
              ),
      ),
    );
  }

  Widget _stage() {
    final src = _preview;
    if (src == null) return _busy();
    Widget view;
    if (_comparing) {
      view = CustomPaint(painter: _ImagePainter(src), size: Size.infinite); // ignores the crop: the whole original
    } else if (_tool == _Tool.crop) {
      view = _CropStage(image: src, params: _p, onLive: _live, onCommit: _commit);
    } else {
      final cropped = _cropped;
      view = cropped == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _FinishStage(image: cropped, params: _p, showBands: _tool == _Tool.body, onLive: _live, onCommit: _commit);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        view,
        // Undo, redo and hold-to-compare float over the photo.
        Positioned(
          top: 4,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xCC16161B), borderRadius: BorderRadius.circular(24)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(tooltip: 'Undo', onPressed: _h > 0 ? _undo : null, icon: const Icon(Icons.undo_rounded)),
                  IconButton(
                    tooltip: 'Redo',
                    onPressed: _h < _history.length - 1 ? _redo : null,
                    icon: const Icon(Icons.redo_rounded),
                  ),
                  GestureDetector(
                    onTapDown: (_) => setState(() => _comparing = true),
                    onTapUp: (_) => setState(() => _comparing = false),
                    onTapCancel: () => setState(() => _comparing = false),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                      child: Row(
                        children: [
                          Icon(Icons.compare_rounded, size: 20, color: _comparing ? accent : ink),
                          const SizedBox(width: 6),
                          Text(
                            _comparing ? 'Original' : 'Hold to compare',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _comparing ? accent : ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_status != null) _busy(),
      ],
    );
  }

  Widget _busy() => ColoredBox(
    color: const Color(0xAA000000),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(_status ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    ),
  );

  Widget _panel() => Container(
    color: surface,
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: switch (_tool) {
                _Tool.crop => _CropTools(
                  params: _p,
                  photo: Size(_preview!.width.toDouble(), _preview!.height.toDouble()),
                  onLive: _live,
                  onCommit: _commit,
                ),
                _Tool.body => _BodyTools(params: _p, onLive: _live, onCommit: _commit),
                _Tool.adjust => _AdjustTools(params: _p, thumb: _cropped, onLive: _live, onCommit: _commit),
              },
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              for (final (tool, icon, label) in const [
                (_Tool.crop, Icons.crop_rotate_rounded, 'Crop'),
                (_Tool.body, Icons.accessibility_new_rounded, 'Body'),
                (_Tool.adjust, Icons.tune_rounded, 'Adjust'),
              ])
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _tool = tool),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        children: [
                          Icon(icon, color: _tool == tool ? accent : muted),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: _tool == tool ? accent : muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

// --- Painters --------------------------------------------------------------------

/// [content] scaled to fit [box] less [pad] all round, with [top] kept clear for the floating controls.
Rect _fit(Size content, Size box, {double pad = 20, double top = 0}) {
  final avail = Size(math.max(1, box.width - pad * 2), math.max(1, box.height - pad * 2 - top));
  final s = math.min(avail.width / content.width, avail.height / content.height);
  final w = content.width * s, h = content.height * s;
  return Rect.fromLTWH((box.width - w) / 2, top + (box.height - top - h) / 2, w, h);
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.image);
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Size(image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(
      image,
      Offset.zero & src,
      _fit(src, size, top: 56),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_ImagePainter old) => old.image != image;
}

/// The whole photo (rotated, straightened, coloured) with the crop frame over it.
class _OrientedPainter extends CustomPainter {
  _OrientedPainter(this.image, this.params, this.rect);
  final ui.Image image;
  final EditParams params;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final o = orientedSize(Size(image.width.toDouble(), image.height.toDouble()), params);
    final matrix = matrixFor(params);
    canvas.save();
    canvas.clipRect(rect);
    if (!isIdentity(matrix)) canvas.saveLayer(rect, Paint()..colorFilter = ColorFilter.matrix(matrix));
    canvas.translate(rect.left, rect.top);
    canvas.scale(rect.width / o.width);
    paintOriented(canvas, image, params, o);
    if (!isIdentity(matrix)) canvas.restore();
    canvas.restore();

    // Dim outside the frame, then the frame, thirds and corner handles.
    final c = params.crop;
    final frame = Rect.fromLTRB(
      rect.left + c.left * rect.width,
      rect.top + c.top * rect.height,
      rect.left + c.right * rect.width,
      rect.top + c.bottom * rect.height,
    );
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(rect.inflate(1)), Path()..addRect(frame)),
      Paint()..color = const Color(0xB3000000),
    );
    final thin = Paint()
      ..color = const Color(0x80FFFFFF)
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3, y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final handle = Paint()
      ..color = accent
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    for (final (p, dx, dy) in [
      (frame.topLeft, 1.0, 1.0),
      (frame.topRight, -1.0, 1.0),
      (frame.bottomRight, -1.0, -1.0),
      (frame.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(l * dx, 0), handle);
      canvas.drawLine(p, p + Offset(0, l * dy), handle);
    }
  }

  @override
  bool shouldRepaint(_OrientedPainter old) => old.image != image || old.params != params || old.rect != rect;
}

/// The cropped photo with the body reshape and colour applied, and the band
/// being reshaped shown over it.
class _FinishPainter extends CustomPainter {
  _FinishPainter(this.image, this.params, this.rect, this.showBands);
  final ui.Image image;
  final EditParams params;
  final Rect rect;
  final bool showBands;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(rect.left, rect.top);
    paintFinish(canvas, image, rect.size, params);
    canvas.restore();
    if (!showBands) return;

    final band = Paint()..color = accent.withValues(alpha: 0.08);
    final edge = Paint()
      ..color = accent
      ..strokeWidth = 1.5;
    final yw = BandWarp(params.heightBand.$1, params.heightBand.$2, params.height);
    final xw = BandWarp(params.widthBand.$1, params.widthBand.$2, params.width);
    final top = rect.top + yw.map(params.heightBand.$1) * rect.height;
    final bottom = rect.top + yw.map(params.heightBand.$2) * rect.height;
    final left = rect.left + xw.map(params.widthBand.$1) * rect.width;
    final right = rect.left + xw.map(params.widthBand.$2) * rect.width;
    canvas.drawRect(Rect.fromLTRB(rect.left, top, rect.right, bottom), band);
    canvas.drawRect(Rect.fromLTRB(left, rect.top, right, rect.bottom), band);
    for (final y in [top, bottom]) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), edge);
      _pill(canvas, Offset(rect.right - 26, y), horizontal: true);
    }
    for (final x in [left, right]) {
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), edge);
      _pill(canvas, Offset(x, rect.bottom - 26), horizontal: false);
    }
  }

  static void _pill(Canvas canvas, Offset c, {required bool horizontal}) {
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: horizontal ? 34 : 14, height: horizontal ? 14 : 34),
      const Radius.circular(7),
    );
    canvas.drawRRect(r, Paint()..color = accent);
    final grip = Paint()
      ..color = onAccent
      ..strokeWidth = 1.5;
    for (final d in [-4.0, 0.0, 4.0]) {
      if (horizontal) {
        canvas.drawLine(c + Offset(d, -3), c + Offset(d, 3), grip);
      } else {
        canvas.drawLine(c + Offset(-3, d), c + Offset(3, d), grip);
      }
    }
  }

  @override
  bool shouldRepaint(_FinishPainter old) =>
      old.image != image || old.params != params || old.rect != rect || old.showBands != showBands;
}

// --- Stages (the big preview, with its gestures) -------------------------------------

class _CropStage extends StatefulWidget {
  const _CropStage({required this.image, required this.params, required this.onLive, required this.onCommit});
  final ui.Image image;
  final EditParams params;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;

  @override
  State<_CropStage> createState() => _CropStageState();
}

class _CropStageState extends State<_CropStage> {
  Rect? _startCrop;
  int? _corner; // null = moving the whole frame
  Offset _total = Offset.zero;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final o = orientedSize(Size(widget.image.width.toDouble(), widget.image.height.toDouble()), widget.params);
      final rect = _fit(o, box.biggest, pad: 28, top: 56);
      return GestureDetector(
        onPanStart: (d) {
          final c = widget.params.crop;
          final frame = Rect.fromLTRB(
            rect.left + c.left * rect.width,
            rect.top + c.top * rect.height,
            rect.left + c.right * rect.width,
            rect.top + c.bottom * rect.height,
          );
          final corners = [frame.topLeft, frame.topRight, frame.bottomRight, frame.bottomLeft];
          int? hit;
          var best = 40.0;
          for (var i = 0; i < 4; i++) {
            final dist = (corners[i] - d.localPosition).distance;
            if (dist < best) {
              best = dist;
              hit = i;
            }
          }
          _corner = hit;
          _startCrop = c;
          _total = Offset.zero;
        },
        onPanUpdate: (d) {
          final start = _startCrop;
          if (start == null) return;
          _total += Offset(d.delta.dx / rect.width, d.delta.dy / rect.height);
          final p = widget.params;
          final corner = _corner;
          final crop = corner == null
              ? moveCrop(start, _total)
              : resizeCrop(start, corner, _total, normalizedRatio(o, _ratio(p, o)));
          widget.onLive(p.copyWith(crop: crop));
        },
        onPanEnd: (_) {
          _startCrop = null;
          widget.onCommit();
        },
        child: CustomPaint(painter: _OrientedPainter(widget.image, widget.params, rect), size: Size.infinite),
      );
    },
  );

  static double? _ratio(EditParams p, Size o) =>
      p.aspect == AspectPreset.original ? o.width / o.height : p.aspect.ratio;
}

class _FinishStage extends StatefulWidget {
  const _FinishStage({
    required this.image,
    required this.params,
    required this.showBands,
    required this.onLive,
    required this.onCommit,
  });
  final ui.Image image;
  final EditParams params;
  final bool showBands;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;

  @override
  State<_FinishStage> createState() => _FinishStageState();
}

class _FinishStageState extends State<_FinishStage> {
  int? _edge; // 0 top, 1 bottom, 2 left, 3 right

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
      final rect = _fit(size, box.biggest, pad: 16, top: 56);
      final painter = CustomPaint(
        painter: _FinishPainter(widget.image, widget.params, rect, widget.showBands),
        size: Size.infinite,
      );
      if (!widget.showBands) return painter;
      return GestureDetector(
        onPanStart: (d) {
          final p = widget.params;
          final yw = BandWarp(p.heightBand.$1, p.heightBand.$2, p.height);
          final xw = BandWarp(p.widthBand.$1, p.widthBand.$2, p.width);
          final pos = d.localPosition;
          final candidates = [
            ((rect.top + yw.map(p.heightBand.$1) * rect.height - pos.dy).abs(), 0),
            ((rect.top + yw.map(p.heightBand.$2) * rect.height - pos.dy).abs(), 1),
            ((rect.left + xw.map(p.widthBand.$1) * rect.width - pos.dx).abs(), 2),
            ((rect.left + xw.map(p.widthBand.$2) * rect.width - pos.dx).abs(), 3),
          ]..sort((a, b) => a.$1.compareTo(b.$1));
          _edge = candidates.first.$1 < 44 ? candidates.first.$2 : null;
          if (_edge != null) HapticFeedback.selectionClick();
        },
        onPanUpdate: (d) {
          final edge = _edge;
          if (edge == null) return;
          final p = widget.params;
          final pos = d.localPosition;
          if (edge < 2) {
            final yw = BandWarp(p.heightBand.$1, p.heightBand.$2, p.height);
            final v = yw.unmap(((pos.dy - rect.top) / rect.height).clamp(0.0, 1.0));
            final band = edge == 0
                ? (math.min(v, p.heightBand.$2 - 0.05), p.heightBand.$2)
                : (p.heightBand.$1, math.max(v, p.heightBand.$1 + 0.05));
            widget.onLive(p.copyWith(heightBand: band));
          } else {
            final xw = BandWarp(p.widthBand.$1, p.widthBand.$2, p.width);
            final u = xw.unmap(((pos.dx - rect.left) / rect.width).clamp(0.0, 1.0));
            final band = edge == 2
                ? (math.min(u, p.widthBand.$2 - 0.05), p.widthBand.$2)
                : (p.widthBand.$1, math.max(u, p.widthBand.$1 + 0.05));
            widget.onLive(p.copyWith(widthBand: band));
          }
        },
        onPanEnd: (_) {
          if (_edge != null) widget.onCommit();
          _edge = null;
        },
        child: painter,
      );
    },
  );
}

// --- Tool panels -------------------------------------------------------------------

class _CropTools extends StatelessWidget {
  const _CropTools({required this.params, required this.photo, required this.onLive, required this.onCommit});
  final EditParams params;
  final Size photo; // the preview source, before any turns
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;

  Size get _o => orientedSize(photo, params);

  void _aspect(AspectPreset a) {
    final ratio = a == AspectPreset.original ? _o.width / _o.height : a.ratio;
    final crop = a == AspectPreset.free
        ? params.crop
        : a == AspectPreset.original
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : refitCrop(params.crop, normalizedRatio(_o, ratio));
    onCommit(params.copyWith(aspect: a, crop: crop));
  }

  void _turn(int by) {
    final p = params.copyWith(quarterTurns: (params.quarterTurns + by) % 4);
    final o = orientedSize(photo, p);
    // The frame lives in the turned photo, so start it afresh for the new shape.
    final ratio = p.aspect == AspectPreset.original ? o.width / o.height : p.aspect.ratio;
    onCommit(p.copyWith(crop: centeredCrop(o, p.aspect == AspectPreset.free ? null : ratio)));
  }

  @override
  Widget build(BuildContext context) {
    final aspect = cropAspect(params.crop, _o);
    final feedOk = fitsFeed(aspect);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in AspectPreset.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(a.label),
                    selected: params.aspect == a,
                    onSelected: (_) => _aspect(a),
                    labelStyle: TextStyle(fontWeight: FontWeight.w800, color: params.aspect == a ? onAccent : ink),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Rotate left',
                onPressed: () => _turn(3),
                icon: const Icon(Icons.rotate_90_degrees_ccw_rounded),
              ),
              IconButton(
                tooltip: 'Rotate right',
                onPressed: () => _turn(1),
                icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
              ),
              IconButton(
                tooltip: 'Flip',
                onPressed: () => onCommit(params.copyWith(flipH: !params.flipH)),
                icon: const Icon(Icons.flip_rounded),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.straighten_rounded, size: 18, color: muted),
              Expanded(
                child: Slider(
                  min: -20,
                  max: 20,
                  value: params.straighten.clamp(-20, 20),
                  onChanged: (v) => onLive(params.copyWith(straighten: (v * 2).roundToDouble() / 2)),
                  onChangeEnd: (_) => onCommit(),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${params.straighten.toStringAsFixed(params.straighten % 1 == 0 ? 0 : 1)}°',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              Icon(
                feedOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                size: 16,
                color: feedOk ? positive : accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  feedOk
                      ? 'Fits an Instagram post'
                      : 'Too ${aspect < 0.8 ? 'tall' : 'wide'} for an Instagram post (4:5 to 1.91:1). Fine for a story.',
                  style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BodyTools extends StatelessWidget {
  const _BodyTools({required this.params, required this.onLive, required this.onCommit});
  final EditParams params;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Drag the yellow lines to cover the person: the across band sets height (legs work best), '
          'the up-down band sets width.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600, height: 1.35),
        ),
        const SizedBox(height: 6),
        _LabeledSlider(
          leading: 'Shorter',
          trailing: 'Taller',
          value: params.height,
          onChanged: (v) => onLive(params.copyWith(height: v)),
          onEnd: onCommit,
        ),
        _LabeledSlider(
          leading: 'Thinner',
          trailing: 'Wider',
          value: params.width,
          onChanged: (v) => onLive(params.copyWith(width: v)),
          onEnd: onCommit,
        ),
      ],
    ),
  );
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.leading,
    required this.trailing,
    required this.value,
    required this.onChanged,
    required this.onEnd,
  });
  final String leading, trailing;
  final double value;
  static const range = 0.4;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 62,
        child: Text(
          leading,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: muted),
        ),
      ),
      Expanded(
        child: Slider(
          min: -range,
          max: range,
          value: value.clamp(-range, range),
          onChanged: (v) => onChanged(v.abs() < range * 0.03 ? 0 : v), // snaps back to "no change"
          onChangeEnd: (_) => onEnd(),
        ),
      ),
      SizedBox(
        width: 62,
        child: Text(
          trailing,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: muted),
        ),
      ),
    ],
  );
}

enum _Adjust { brightness, contrast, saturation, warmth }

class _AdjustTools extends StatefulWidget {
  const _AdjustTools({required this.params, required this.thumb, required this.onLive, required this.onCommit});
  final EditParams params;
  final ui.Image? thumb;
  final ValueChanged<EditParams> onLive;
  final void Function([EditParams?]) onCommit;

  @override
  State<_AdjustTools> createState() => _AdjustToolsState();
}

class _AdjustToolsState extends State<_AdjustTools> {
  _Adjust? _slider; // null = the filter strip

  double _value(_Adjust a) => switch (a) {
    _Adjust.brightness => widget.params.brightness,
    _Adjust.contrast => widget.params.contrast,
    _Adjust.saturation => widget.params.saturation,
    _Adjust.warmth => widget.params.warmth,
  };

  EditParams _with(_Adjust a, double v) => switch (a) {
    _Adjust.brightness => widget.params.copyWith(brightness: v),
    _Adjust.contrast => widget.params.copyWith(contrast: v),
    _Adjust.saturation => widget.params.copyWith(saturation: v),
    _Adjust.warmth => widget.params.copyWith(warmth: v),
  };

  @override
  Widget build(BuildContext context) {
    final slider = _slider;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _chip('Filters', slider == null, () => setState(() => _slider = null)),
              for (final a in _Adjust.values)
                _chip(
                  '${a.name[0].toUpperCase()}${a.name.substring(1)}${_value(a).abs() > 0.005 ? ' •' : ''}',
                  slider == a,
                  () => setState(() => _slider = a),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: slider == null
              ? SizedBox(
                  key: const ValueKey('filters'),
                  height: 104,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [for (final f in filterPresets) _filterTile(f)],
                  ),
                )
              : Padding(
                  key: ValueKey(slider),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: -1,
                          max: 1,
                          value: _value(slider).clamp(-1, 1),
                          onChanged: (v) => widget.onLive(_with(slider, v.abs() < 0.03 ? 0 : v)),
                          onChangeEnd: (_) => widget.onCommit(),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(_value(slider) * 100).round()}',
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Reset',
                        onPressed: _value(slider) == 0 ? null : () => widget.onCommit(_with(slider, 0)),
                        icon: const Icon(Icons.restart_alt_rounded),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(fontWeight: FontWeight.w800, color: selected ? onAccent : ink),
    ),
  );

  Widget _filterTile(FilterPreset f) {
    final selected = widget.params.filter == f.id;
    final thumb = widget.thumb;
    return GestureDetector(
      onTap: () => widget.onCommit(widget.params.copyWith(filter: f.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? accent : Colors.transparent, width: 2.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: thumb == null
                    ? const ColoredBox(color: surfaceHigh)
                    : ColorFiltered(
                        colorFilter: ColorFilter.matrix(f.build()),
                        child: RawImage(image: thumb, fit: BoxFit.cover, filterQuality: FilterQuality.low),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              f.label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: selected ? accent : muted),
            ),
          ],
        ),
      ),
    );
  }
}
