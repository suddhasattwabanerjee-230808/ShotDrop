import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_channel.dart';
import '../card_channel.dart';
import '../edit/crop.dart';
import '../edit/story.dart';
import '../models.dart';
import '../publish.dart';
import '../share_channel.dart';
import '../theme.dart';
import '../widgets.dart';
import 'app_screens.dart';
import 'setup_screen.dart';

/// The Publish sheet: how to post [items] (the ones ticked in the Upload
/// folder; the rest stay there). Starts [PublishScreen].
Future<void> showPublishSheet(BuildContext context, List<UploadItem> items) async {
  final scope = AppScope.of(context);
  if (items.isEmpty) return;
  ({bool instagram, bool facebook}) apps;
  try {
    apps = await ShareChannel.instance.installedApps();
  } catch (_) {
    apps = (instagram: false, facebook: false);
  }
  if (!context.mounted) return;
  final choice = await showModalBottomSheet<(PublishMode, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PublishSheet(items: items, apps: apps, scope: scope),
  );
  if (choice == null || !context.mounted) return;
  final (mode, facebook) = choice;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PublishScreen(
        steps: buildPlan(items, mode, facebook: facebook),
        mode: mode,
      ),
    ),
  );
}

class _PublishSheet extends StatefulWidget {
  const _PublishSheet({required this.items, required this.apps, required this.scope});
  final List<UploadItem> items;
  final ({bool instagram, bool facebook}) apps;
  final AppScope scope;

  @override
  State<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<_PublishSheet> {
  late var _mode = PublishMode.values.asNameMap()[widget.scope.settings.publishMode] ?? PublishMode.post;
  late bool _facebook = widget.apps.facebook && !widget.scope.social.instagramSharesToFacebook;

  int get _n => widget.items.length;

  String _describe(PublishMode m) {
    final posts = (_n / carouselMax).ceil();
    final post = _n == 1
        ? '1 Post'
        : posts == 1
        ? '1 Carousel Of $_n'
        : '$posts Carousels';
    final stories = _n == 1 ? '1 Story' : '$_n Stories';
    return switch (m) {
      PublishMode.post => post,
      PublishMode.postAndStory => '$post + $stories',
      PublishMode.story => stories,
    };
  }

  @override
  Widget build(BuildContext context) {
    final social = widget.scope.social;
    final caption = widget.scope.uploads.caption.trim();
    final tooTall = widget.items.where((i) => i.aspect != null && !fitsFeed(i.aspect!)).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Publish $_n ${_n == 1 ? 'Photo' : 'Photos'}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetupScreen())),
              child: ListenableBuilder(
                listenable: social,
                builder: (context, _) => Text(
                  social.handle.isEmpty ? 'To Instagram · Set Your Username' : 'To Instagram As @${social.handle}',
                  style: const TextStyle(color: accent, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final m in PublishMode.values)
              _ModeCard(mode: m, detail: _describe(m), selected: _mode == m, onTap: () => setState(() => _mode = m)),
            if (_mode.hasPost && tooTall > 0)
              _Note(
                icon: Icons.info_outline_rounded,
                text:
                    '$tooTall ${tooTall == 1 ? 'photo is' : 'photos are'} outside Instagram\'s post shape (4:5 to 1.91:1), '
                    'so Instagram will crop ${tooTall == 1 ? 'it' : 'them'}. Fine for stories.',
              ),
            if (_mode.hasPost)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _facebook,
                onChanged: widget.apps.facebook ? (v) => setState(() => _facebook = v) : null,
                title: const Text('Also Open Facebook For The Post', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  !widget.apps.facebook
                      ? 'The Facebook app isn\'t installed.'
                      : social.instagramSharesToFacebook
                      ? 'Not needed: Instagram already shares your posts to Facebook.'
                      : 'Only needed if Instagram doesn\'t share to Facebook by itself.',
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              ),
            _Note(
              icon: Icons.notes_rounded,
              text: caption.isEmpty
                  ? 'No caption. You can add one in the Upload folder.'
                  : 'Caption: ${caption.length > 80 ? '${caption.substring(0, 80)}…' : caption}',
            ),
            const SizedBox(height: 12),
            if (widget.apps.instagram)
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, (_mode, _mode.hasPost && _facebook)),
                icon: const Icon(Icons.send_rounded),
                label: const Text('Start'),
              )
            else
              FilledButton.icon(
                onPressed: () => ShareChannel.instance.openUrl(
                  'https://play.google.com/store/apps/details?id=com.instagram.android',
                ),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Install Instagram First'),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.detail, required this.selected, required this.onTap});
  final PublishMode mode;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (mode) {
    PublishMode.post => Icons.grid_on_rounded,
    PublishMode.postAndStory => Icons.dynamic_feed_rounded,
    PublishMode.story => Icons.amp_stories_rounded,
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0x1FFFD21F) : surfaceHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? accent : Colors.transparent, width: 1.5),
        ),
        child: Row(
          children: [
            Icon(_icon, color: selected ? accent : muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  Text(
                    detail,
                    style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: const Icon(Icons.check_circle_rounded, color: accent),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: muted, height: 1.4)),
        ),
      ],
    ),
  );
}

// --- The publishing walk-through ------------------------------------------------

enum _Status { pending, done, skipped }

/// Goes through the plan one step at a time: open Instagram (or Facebook)
/// with the photos, come back, say whether it posted. Photos whose posts or
/// stories went out are marked as posted when this screen closes.
class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key, required this.steps, required this.mode});
  final List<PublishStep> steps;
  final PublishMode mode;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  late final _steps = [...widget.steps];
  late final _status = [for (final _ in widget.steps) _Status.pending];
  late final _uploads = AppScope.of(context).uploads;
  int _current = 0;
  bool _opened = false; // the current step has been sent out at least once
  String? _busy;

  bool get _finished => _current >= _steps.length;

  Set<String> get _postedIds => {
    for (var i = 0; i < _steps.length; i++)
      if (_status[i] == _Status.done && _steps[i].kind != StepKind.facebookPost)
        for (final item in _steps[i].items) item.shotId,
  };

  bool _helperOn = false; // caption auto-paste is switched on

  Future<bool> _helper() async {
    final on = await AppChannel.instance.captionHelperOn().catchError((Object _) => false);
    if (mounted && on != _helperOn) setState(() => _helperOn = on);
    return on;
  }

  @override
  void initState() {
    super.initState();
    _helper();
  }

  @override
  void dispose() {
    final ids = _postedIds;
    _uploads.finishPublishing(ids);
    super.dispose();
  }

  Future<void> _open() async {
    final step = _steps[_current];
    final messenger = ScaffoldMessenger.of(context);
    try {
      List<String> paths;
      if (step.kind == StepKind.instagramStory) {
        setState(() => _busy = 'Getting The Story Ready…');
        paths = [await _storyFile(step.items.single)];
      } else {
        paths = [for (final i in step.items) i.previewPath];
      }
      // An Instagram post gets the caption typed in by the helper when it's on; otherwise it's copied for pasting.
      final caption = step.kind == StepKind.instagramStory ? '' : _uploads.caption.trim();
      final typed = step.kind == StepKind.instagramPost && caption.isNotEmpty && await _helper();
      if (caption.isNotEmpty && !typed) await copyCaption(messenger, caption);
      setState(() => _busy = null);
      final app = step.kind == StepKind.facebookPost ? SocialApp.facebook : SocialApp.instagram;
      final kind = step.kind == StepKind.instagramStory ? ShareKind.story : ShareKind.feed;
      switch (await ShareChannel.instance.share(app, kind, paths, caption: typed ? caption : null)) {
        case ShareOutcome.launched:
        case ShareOutcome.chooser:
          setState(() => _opened = true);
        case ShareOutcome.noMultiple:
          _splitCurrent();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                '${app == SocialApp.facebook ? 'Facebook' : 'Instagram'} won\'t take several photos at '
                'once here, so they\'ll go one post at a time.',
              ),
            ),
          );
        case ShareOutcome.notInstalled:
          messenger.showSnackBar(
            SnackBar(content: Text('${app == SocialApp.facebook ? 'Facebook' : 'Instagram'} isn\'t installed.')),
          );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t Open It: $e')));
    }
  }

  /// The story version of [item]: 9:16 over a blurred copy of itself. Made once, then reused.
  Future<String> _storyFile(UploadItem item) async {
    final path = item.previewPath.replaceFirst(RegExp(r'\.jpg$'), '-story.jpg');
    if (await File(path).exists()) return path;
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(item.previewPath).readAsBytes());
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final frame = await (await descriptor.instantiateCodec()).getNextFrame();
    final story = await renderStory(frame.image);
    frame.image.dispose();
    final rgba = await story.toByteData(format: ui.ImageByteFormat.rawRgba);
    await CardChannel.instance.encodeJpeg(rgba!.buffer.asUint8List(), story.width, story.height, path);
    story.dispose();
    return path;
  }

  /// Replaces the current multi-photo step with one step per photo.
  void _splitCurrent() {
    final step = _steps[_current];
    setState(() {
      _steps.replaceRange(_current, _current + 1, [
        for (final i in step.items) PublishStep(step.kind, [i]),
      ]);
      _status.replaceRange(_current, _current + 1, [for (final _ in step.items) _Status.pending]);
    });
  }

  void _resolve(_Status s) {
    HapticFeedback.mediumImpact();
    setState(() {
      _status[_current] = s;
      _current++;
      _opened = false;
    });
  }

  Future<bool> _confirmLeave() async {
    if (_finished || _status.every((s) => s == _Status.pending)) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop publishing?'),
        content: const Text('What you\'ve posted so far is saved. The rest stays in the Upload folder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep Going')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stop')),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final social = AppScope.of(context).social;
    final done = _status.where((s) => s != _Status.pending).length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmLeave()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_finished ? 'All Done' : 'Publishing'),
              Text(
                '${widget.mode.label}${social.handle.isEmpty ? '' : ' · @${social.handle}'}',
                style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        body: _finished ? _summary() : _walkthrough(done),
      ),
    );
  }

  Widget _walkthrough(int done) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: done / _steps.length),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) =>
              LinearProgressIndicator(value: v, minHeight: 6, backgroundColor: line, color: accent),
        ),
      ),
      const SizedBox(height: 8),
      Text('Step ${_current + 1} Of ${_steps.length}', style: sectionLabel),
      const SizedBox(height: 12),
      for (var i = 0; i < _steps.length; i++)
        i == _current ? _currentCard(_steps[i]) : _StepRow(step: _steps[i], status: _status[i], index: i),
    ],
  );

  Widget _currentCard(PublishStep step) {
    final facebook = step.kind == StepKind.facebookPost;
    final appName = facebook ? 'Facebook' : 'Instagram';
    final story = step.kind == StepKind.instagramStory;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _KindIcon(kind: step.kind, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(step.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Thumbs(items: step.items, story: story),
          const SizedBox(height: 12),
          Text(
            _opened
                ? 'Did it post? Tap ${facebook ? 'Post' : 'Share'} in $appName, then come back here.'
                : story
                ? 'Instagram opens its story editor with this photo. Add stickers or text if you like, then tap Your story.'
                : facebook
                ? 'Facebook opens a new post with ${step.items.length == 1 ? 'this photo' : 'these photos'}. Paste the caption and tap Post.'
                : 'Instagram opens a new post with ${step.items.length == 1 ? 'this photo' : 'these photos'}. '
                      '${_uploads.caption.trim().isEmpty ? 'Tap Share.' : _helperOn ? 'ShotDrop types the caption in for you; check it, then tap Share.' : 'The caption is copied: long-press the caption box and tap Paste, then Share.'}',
            style: const TextStyle(fontSize: 13, color: muted, height: 1.45),
          ),
          if (step.kind == StepKind.instagramPost && !_opened && !_helperOn && _uploads.caption.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () async {
                  await Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const CaptionHelperScreen()));
                  _helper();
                },
                icon: const Icon(Icons.content_paste_go_rounded, size: 18),
                label: const Text('Have ShotDrop Type The Caption In'),
              ),
            ),
          const SizedBox(height: 14),
          if (_busy != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(_busy!, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            )
          else if (!_opened) ...[
            FilledButton.icon(
              onPressed: _open,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text('Open $appName'),
            ),
            TextButton(onPressed: () => _resolve(_Status.skipped), child: const Text('Skip This One')),
          ] else ...[
            FilledButton.icon(
              onPressed: () => _resolve(_Status.done),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Yes, It\'s Posted'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: _open, child: const Text('Open Again')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(onPressed: () => _resolve(_Status.skipped), child: const Text('Skip')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary() {
    final ids = _postedIds;
    final posts = _steps.indexed.where((e) => _status[e.$1] == _Status.done && e.$2.kind == StepKind.instagramPost);
    final stories = _steps.indexed.where((e) => _status[e.$1] == _Status.done && e.$2.kind == StepKind.instagramStory);
    final fbShares = AppScope.of(context).social.instagramSharesToFacebook;
    final nothing = ids.isEmpty;
    final counts = [
      '${ids.length} ${ids.length == 1 ? 'Photo' : 'Photos'}',
      if (posts.isNotEmpty) '${posts.length} ${posts.length == 1 ? 'Post' : 'Posts'}',
      if (stories.isNotEmpty) '${stories.length} ${stories.length == 1 ? 'Story' : 'Stories'}',
    ].join(' · ');
    final facebook = fbShares ? '\nInstagram shares them to your Facebook too.' : '';
    return StatePanel(
      icon: nothing ? Icons.outbox_rounded : Icons.check_rounded,
      iconWidget: nothing ? null : const _DoneBadge(),
      title: nothing ? 'Nothing Was Posted' : 'Posted To Instagram',
      body: nothing
          ? 'Everything is still in the Upload folder for next time.'
          : '$counts$facebook\nThe edited copies are now in Pictures/ShotDrop/Published.',
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
          child: const Text('Back To The Card'),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.status, required this.index});
  final PublishStep step;
  final _Status status;
  final int index;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Row(
      children: [
        _KindIcon(kind: step.kind, active: false, status: status),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            step.title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: status == _Status.pending ? ink : muted,
              decoration: status == _Status.skipped ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        Text(
          switch (status) {
            _Status.pending => '',
            _Status.done => 'Posted',
            _Status.skipped => 'Skipped',
          },
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: status == _Status.done ? positive : muted),
        ),
      ],
    ),
  );
}

class _KindIcon extends StatelessWidget {
  const _KindIcon({required this.kind, required this.active, this.status = _Status.pending});
  final StepKind kind;
  final bool active;
  final _Status status;

  @override
  Widget build(BuildContext context) {
    final icon = switch (status) {
      _Status.done => Icons.check_rounded,
      _Status.skipped => Icons.redo_rounded,
      _Status.pending => switch (kind) {
        StepKind.instagramPost => Icons.grid_on_rounded,
        StepKind.instagramStory => Icons.amp_stories_rounded,
        StepKind.facebookPost => Icons.facebook_rounded,
      },
    };
    final bg = status == _Status.done
        ? positive
        : active
        ? accent
        : surfaceHigh;
    final fg = status == _Status.done
        ? const Color(0xFF06210F)
        : active
        ? onAccent
        : muted;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
      child: Icon(icon, size: 19, color: fg),
    );
  }
}

class _Thumbs extends StatelessWidget {
  const _Thumbs({required this.items, required this.story});
  final List<UploadItem> items;
  final bool story;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(5).toList();
    return SizedBox(
      height: story ? 96 : 64,
      child: Row(
        children: [
          for (final (i, item) in shown.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: story ? 54 : 64,
                  height: story ? 96 : 64,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(item.previewPath),
                        fit: BoxFit.cover,
                        cacheWidth: 200,
                        errorBuilder: (_, _, _) => const ColoredBox(color: surfaceHigh),
                      ),
                      if (i == shown.length - 1 && items.length > shown.length)
                        ColoredBox(
                          color: const Color(0x99000000),
                          child: Center(
                            child: Text(
                              '+${items.length - shown.length}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DoneBadge extends StatelessWidget {
  const _DoneBadge();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 600),
    curve: Curves.elasticOut,
    builder: (context, v, _) => Transform.scale(
      scale: v,
      child: Container(
        width: 96,
        height: 96,
        decoration: const BoxDecoration(color: positive, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded, size: 52, color: Color(0xFF06210F)),
      ),
    ),
  );
}
