import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_channel.dart';
import '../card_channel.dart';
import '../edit/post_shape.dart';
import '../edit/story.dart';
import '../models.dart';
import '../publish.dart';
import '../share_channel.dart';
import '../storage.dart';
import '../stores.dart';
import '../theme.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'app_screens.dart';
import 'setup_screen.dart';

/// The Publish sheet: how to post [items] (the ones ticked in the Upload
/// folder; the rest stay there). Start sends the first of them straight out
/// to Instagram; "Did It Post?" ([PublishScreen]) comes up on the way back.
Future<void> showPublishSheet(BuildContext context, List<UploadItem> items) async {
  final scope = AppScope.of(context);
  if (items.isEmpty) return;
  ({bool instagram, bool facebook}) apps;
  try {
    apps = await ShareChannel.instance.installedApps();
  } catch (_) {
    apps = (instagram: false, facebook: false);
  }
  final aspects = await Future.wait([for (final i in items) i.aspect != null ? Future.value(i.aspect) : photoAspect(i.previewPath)]);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PublishSheet(items: items, apps: apps, scope: scope, reshaped: reshapedCount(aspects)),
  );
}

/// Width / height of the photo at [path], read from its header; null if it can't be read.
Future<double?> photoAspect(String path) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
    final d = await ui.ImageDescriptor.encoded(buffer);
    final aspect = d.width / d.height;
    d.dispose();
    buffer.dispose();
    return aspect;
  } catch (_) {
    return null;
  }
}

class _PublishSheet extends StatefulWidget {
  const _PublishSheet({required this.items, required this.apps, required this.scope, required this.reshaped});
  final List<UploadItem> items;
  final int reshaped; // photos that don't fit an Instagram post as they are
  final ({bool instagram, bool facebook}) apps;
  final AppScope scope;

  @override
  State<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<_PublishSheet> {
  late var _mode = PublishMode.values.asNameMap()[widget.scope.settings.publishMode] ?? PublishMode.post;
  late bool _facebook = widget.apps.facebook && !widget.scope.social.instagramSharesToFacebook;
  late var _fit = PostFit.values.asNameMap()[widget.scope.settings.postFit] ?? PostFit.crop;
  String? _busy; // getting the photos ready, after Start

  Future<void> _start() async {
    final uploads = widget.scope.uploads;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    HapticFeedback.mediumImpact();
    setState(() => _busy = 'Getting Ready…');
    await uploads.setSession(
      PublishSession(
        mode: _mode,
        steps: buildPlan(widget.items, _mode, facebook: _mode.hasPost && _facebook),
        fit: _fit,
      ),
    );
    final error = await openStep(uploads, messenger, busy: (b) => mounted ? setState(() => _busy = b) : null);
    if (error != null) await uploads.setSession(null);
    navigator.pop();
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

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
    final reshaped = widget.reshaped;
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
                  style: TextStyle(color: accent, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final m in PublishMode.values)
              _ModeCard(mode: m, detail: _describe(m), selected: _mode == m, onTap: () => setState(() => _mode = m)),
            if (_mode.hasPost && reshaped > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$reshaped ${reshaped == 1 ? 'Photo Doesn\'t' : 'Photos Don\'t'} Fit An Instagram Post',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                widget.items.length > 1
                    ? 'Posts go from 4:5 (tall) to 1.91:1 (wide), and a carousel takes its first photo\'s shape.'
                    : 'Posts go from 4:5 (tall) to 1.91:1 (wide).',
                style: TextStyle(fontSize: 12, color: muted, height: 1.4),
              ),
              const SizedBox(height: 8),
              SegmentedButton<PostFit>(
                showSelectedIcon: false,
                segments: [for (final f in PostFit.values) ButtonSegment(value: f, label: Text(f.label))],
                selected: {_fit},
                onSelectionChanged: (s) => setState(() => _fit = s.single),
              ),
              _Note(icon: Icons.info_outline_rounded, text: '${_fit.detail}. Stories always show the whole photo.'),
            ],
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
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
            _Note(
              icon: Icons.notes_rounded,
              text: caption.isEmpty
                  ? 'No caption. You can add one in the Upload folder.'
                  : 'Caption: ${caption.length > 80 ? '${caption.substring(0, 80)}…' : caption}',
            ),
            const SizedBox(height: 12),
            if (_busy != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(_busy!, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              )
            else if (widget.apps.instagram)
              FilledButton.icon(
                onPressed: _start,
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
          color: selected ? accent.withValues(alpha: 0.12) : surfaceHigh,
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
                    style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.check_circle_rounded, color: accent),
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
          child: Text(text, style: TextStyle(fontSize: 12, color: muted, height: 1.4)),
        ),
      ],
    ),
  );
}

// --- Sending a step out -----------------------------------------------------------

/// Opens Instagram (or Facebook) on the current step of the publishing
/// session, with its photos (reshaped for a post, or laid out for a story)
/// and the caption. [busy] says what's under way. Returns what went wrong,
/// or null.
Future<String?> openStep(UploadStore uploads, ScaffoldMessengerState messenger, {ValueChanged<String?>? busy}) async {
  final session = uploads.session;
  final step = session?.step;
  if (session == null || step == null) return null;
  final app = step.kind == StepKind.facebookPost ? SocialApp.facebook : SocialApp.instagram;
  final name = app == SocialApp.facebook ? 'Facebook' : 'Instagram';
  try {
    final List<String> paths;
    switch (step.kind) {
      case StepKind.instagramStory:
        busy?.call('Getting The Story Ready…');
        paths = [await _storyFile(step.items.single)];
      case StepKind.instagramPost:
        busy?.call(step.items.length == 1 ? 'Getting The Photo Ready…' : 'Getting The Photos Ready…');
        paths = await _postFiles(step.items, session.fit);
      case StepKind.facebookPost:
        paths = [for (final i in step.items) i.previewPath];
    }
    // An Instagram post gets the caption typed in by the helper when it's on; otherwise it's copied for pasting.
    final caption = step.kind == StepKind.instagramStory ? '' : uploads.caption.trim();
    final typed =
        step.kind == StepKind.instagramPost &&
        caption.isNotEmpty &&
        await AppChannel.instance.captionHelperOn().catchError((Object _) => false);
    if (caption.isNotEmpty && !typed) await copyCaption(messenger, caption);
    busy?.call('Opening $name…');
    final kind = step.kind == StepKind.instagramStory ? ShareKind.story : ShareKind.feed;
    switch (await ShareChannel.instance.share(app, kind, paths, caption: typed ? caption : null)) {
      case ShareOutcome.launched:
      case ShareOutcome.chooser:
        return null;
      case ShareOutcome.noMultiple:
        // One post at a time, then (the step now holds a single photo, so this doesn't repeat).
        session.splitCurrent();
        await uploads.setSession(session);
        messenger.showSnackBar(
          SnackBar(content: Text('$name won\'t take several photos at once here, so they go one post at a time.')),
        );
        return await openStep(uploads, messenger, busy: busy);
      case ShareOutcome.notInstalled:
        return '$name Isn\'t Installed.';
    }
  } catch (e) {
    busy?.call(null);
    return 'Couldn\'t Open $name: $e';
  }
}

/// [path] without its .jpg, for naming the copies made from it.
String _stem(String path) => path.replaceFirst(RegExp(r'\.jpg$'), '');

/// The photo at [path], decoded at most [maxEdge] px on its long side.
Future<ui.Image> _decode(String path, {int maxEdge = 2160}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final wide = descriptor.width >= descriptor.height;
  final big = (wide ? descriptor.width : descriptor.height) > maxEdge;
  final codec = await descriptor.instantiateCodec(
    targetWidth: big && wide ? maxEdge : null,
    targetHeight: big && !wide ? maxEdge : null,
  );
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

Future<void> _saveJpeg(ui.Image image, String path) async {
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  await CardChannel.instance.encodeJpeg(rgba!.buffer.asUint8List(), image.width, image.height, path);
}

/// The story version of [item]: 9:16 over a blurred copy of itself. Made once, then reused.
Future<String> _storyFile(UploadItem item) async {
  final path = '${_stem(item.previewPath)}-story.jpg';
  if (await File(path).exists()) return path;
  final photo = await _decode(item.previewPath);
  final story = await renderStory(photo);
  photo.dispose();
  await _saveJpeg(story, path);
  story.dispose();
  return path;
}

/// The files for one post of [items]: each in the first one's shape (within
/// Instagram's limits), reshaped by [fit] where it isn't already. Made once, then reused.
Future<List<String>> _postFiles(List<UploadItem> items, PostFit fit) async {
  final aspects = [for (final i in items) i.aspect ?? await photoAspect(i.previewPath)];
  final first = aspects.first;
  if (first == null) return [for (final i in items) i.previewPath];
  final target = postAspect([first]);
  return [
    for (final (n, item) in items.indexed)
      if (aspects[n] case final a? when needsReshape(a, target))
        await _reshapedFile(item, target, fit)
      else
        item.previewPath,
  ];
}

Future<String> _reshapedFile(UploadItem item, double target, PostFit fit) async {
  final path = '${_stem(item.previewPath)}-post-${fit.name}-${(target * 1000).round()}.jpg';
  if (await File(path).exists()) return path;
  final photo = await _decode(item.previewPath);
  final out = await renderReshaped(photo, target, fit);
  photo.dispose();
  await _saveJpeg(out, path);
  out.dispose();
  return path;
}

// --- "Did It Post?" -----------------------------------------------------------------

/// Comes up when ShotDrop is back in front while a round of publishing is
/// out in Instagram (even after ShotDrop was closed meanwhile): did the
/// current post or story go out? Yes sends the next one straight out; Do It
/// Later keeps the rest in the Upload folder. Photos that went out are
/// marked posted.
class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key});

  static bool _showing = false;

  /// Shows it if a round of publishing is waiting on it, and it isn't up already.
  static void showIfPending(BuildContext context) {
    if (_showing || AppScope.of(context).uploads.session == null) return;
    _showing = true;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const PublishScreen())).whenComplete(() => _showing = false);
  }

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  late final _scope = AppScope.of(context);
  late final _uploads = _scope.uploads;
  PublishSession? _ended; // once it's over: what went out, for the summary
  String? _busy;

  Future<void> _open() async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await openStep(_uploads, messenger, busy: (b) => mounted ? setState(() => _busy = b) : null);
    if (mounted) setState(() => _busy = null);
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _posted() async {
    final s = _uploads.session;
    if (s == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _busy = 'Getting Ready…');
    s.resolve(StepStatus.done);
    if (s.finished) return _finish(s);
    await _uploads.setSession(s);
    await _open(); // the next one goes straight out
  }

  Future<void> _later() async {
    final s = _uploads.session;
    if (s == null) return Navigator.of(context).pop();
    s.stop();
    await _finish(s);
  }

  Future<void> _finish(PublishSession s) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await _uploads.finishPublishing(s.postedIds, later: s.laterIds);
    if (_scope.settings.autoTidy) tidyStorage(_uploads, _scope.settings).ignore();
    if (!mounted) return;
    if (s.postedIds.isEmpty) {
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Kept In The Upload Folder For Later')));
    } else {
      setState(() => _ended = s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final social = _scope.social;
    return PopScope(
      canPop: _ended != null,
      // Back without answering: the same as Do It Later.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _busy == null) _later();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: _ended != null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_ended != null ? 'All Done' : 'Publishing'),
              if (social.handle.isNotEmpty)
                Text(
                  '@${social.handle}',
                  style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          actions: const [ThemeToggle()],
        ),
        body: _ended != null
            ? _summary(_ended!)
            : ListenableBuilder(
                listenable: _uploads,
                builder: (context, _) {
                  final s = _uploads.session;
                  final step = s?.step;
                  return s == null || step == null ? const SizedBox.shrink() : _question(s, step);
                },
              ),
      ),
    );
  }

  Widget _question(PublishSession s, PublishStep step) {
    final appName = step.kind == StepKind.facebookPost ? 'Facebook' : 'Instagram';
    final story = step.kind == StepKind.instagramStory;
    final next = s.nextStep;
    final done = s.status.where((x) => x != StepStatus.pending).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.steps.length > 1) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: done / s.steps.length),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) =>
                      LinearProgressIndicator(value: v, minHeight: 6, backgroundColor: line, color: accent),
                ),
              ),
              const SizedBox(height: 8),
              Text('Step ${s.current + 1} Of ${s.steps.length}', style: sectionLabel),
            ],
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _Thumbs(items: step.items, story: story, large: true),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          switch (step.kind) {
                            StepKind.instagramPost => const InstagramFacebookLogo(),
                            StepKind.instagramStory => const InstagramLogo(size: 30),
                            StepKind.facebookPost => const FacebookLogo(size: 30),
                          },
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(step.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Did It Post?',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap Yes once ${story ? 'the story is up' : 'you\'ve tapped ${step.kind == StepKind.facebookPost ? 'Post' : 'Share'}'} '
                        'in $appName, or Do It Later to keep ${step.items.length == 1 ? 'it' : 'them'} in the Upload folder.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: muted, height: 1.45),
                      ),
                      if (next != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          'Next Up: ${next.title}',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: accent, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_busy != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(_busy!, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              )
            else ...[
              FilledButton.icon(
                onPressed: _posted,
                icon: const Icon(Icons.check_rounded),
                label: Text(next == null ? 'Yes, It\'s Posted' : 'Yes, Open The Next One'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _later, child: const Text('Do It Later')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summary(PublishSession s) {
    final ids = s.postedIds;
    int count(StepKind k) => s.steps.indexed.where((e) => s.status[e.$1] == StepStatus.done && e.$2.kind == k).length;
    final posts = count(StepKind.instagramPost), stories = count(StepKind.instagramStory);
    final later = s.laterIds.length;
    final counts = [
      '${ids.length} ${ids.length == 1 ? 'Photo' : 'Photos'}',
      if (posts > 0) '$posts ${posts == 1 ? 'Post' : 'Posts'}',
      if (stories > 0) '$stories ${stories == 1 ? 'Story' : 'Stories'}',
    ].join(' · ');
    final facebook = _scope.social.instagramSharesToFacebook ? '\nInstagram shares them to your Facebook too.' : '';
    final rest = later == 0 ? '' : '\n$later left in the Upload folder for later.';
    return StatePanel(
      icon: Icons.check_rounded,
      iconWidget: const _DoneBadge(),
      title: 'Posted To Instagram',
      body: '$counts$facebook$rest\nThe edited copies are now in Pictures/ShotDrop/Published.',
      actions: [
        FilledButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: const Text('Done')),
      ],
    );
  }
}

class _Thumbs extends StatelessWidget {
  const _Thumbs({required this.items, required this.story, this.large = false});
  final List<UploadItem> items;
  final bool story;
  final bool large; // "Did It Post?": a single photo shown whole, several in a bigger row

  @override
  Widget build(BuildContext context) {
    if (large && items.length == 1) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.file(
            File(items.single.previewPath),
            fit: BoxFit.contain,
            cacheWidth: 720,
            errorBuilder: (_, _, _) => SizedBox(width: 200, height: 250, child: ColoredBox(color: surfaceHigh)),
          ),
        ),
      );
    }
    final shown = items.take(large ? 4 : 5).toList();
    final side = large ? 76.0 : 64.0;
    return SizedBox(
      height: story ? side * 1.5 : side,
      child: Row(
        mainAxisAlignment: large ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          for (final (i, item) in shown.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: story ? side * 0.84 : side,
                  height: story ? side * 1.5 : side,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(item.previewPath),
                        fit: BoxFit.cover,
                        cacheWidth: 200,
                        errorBuilder: (_, _, _) => ColoredBox(color: surfaceHigh),
                      ),
                      if (i == shown.length - 1 && items.length > shown.length)
                        ColoredBox(
                          color: const Color(0x99000000),
                          child: Center(
                            child: Text(
                              '+${items.length - shown.length}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Colors.white),
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

/// The big green tick, popping in with a burst of confetti.
class _DoneBadge extends StatelessWidget {
  const _DoneBadge();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 1400),
    builder: (context, v, _) => SizedBox(
      width: 240,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _ConfettiBurst(v, rainbow)),
          ),
          Transform.scale(
            scale: Curves.elasticOut.transform((v * 2.2).clamp(0.0, 1.0)),
            child: Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [grass, sky],
                ),
                borderRadius: BorderRadius.circular(38),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 3),
                boxShadow: [BoxShadow(color: deeper(sky, 0.2), offset: const Offset(0, 6))],
              ),
              child: const Icon(Icons.check_rounded, size: 60, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Confetti flying out from the middle as [t] goes 0 to 1, settling on the last frame.
class _ConfettiBurst extends CustomPainter {
  _ConfettiBurst(this.t, this.colors);
  final double t;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final go = Curves.easeOutCubic.transform(t);
    for (var i = 0; i < 22; i++) {
      final angle = i * 2.399963; // spread round evenly (the golden angle)
      final reach = (0.55 + (i * 37 % 10) / 22) * size.height * 0.62 * go;
      final at = c + Offset(math.cos(angle) * reach * 1.45, math.sin(angle) * reach + 14 * t * t);
      final paint = Paint()..color = colors[i % colors.length].withValues(alpha: 0.95);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(angle + t * 4);
      if (i % 3 == 0) {
        canvas.drawCircle(Offset.zero, 4, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 11, height: 5), const Radius.circular(2.5)),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiBurst old) => old.t != t || !listEquals(old.colors, colors);
}
