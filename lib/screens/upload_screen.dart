import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../edit/filters.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_screen.dart';
import 'publish_screen.dart';
import 'home_shell.dart';

/// The Upload folder (a tab): edited photos going out next, in posting order
/// (drag to reorder, swipe back to Selected, tap or Edit to edit again), the
/// caption, and the way out to Instagram. Only the ticked photos are
/// published; once some are posted, the rest go back to Selected for later.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  late final _uploads = AppScope.of(context).uploads;
  late final _caption = TextEditingController(text: _uploads.caption);
  Timer? _saveCaption;
  final _skipped = <String>{}; // shotIds unticked: they stay here for later

  List<UploadItem> get _picked => [
    for (final i in _uploads.queued)
      if (!_skipped.contains(i.shotId)) i,
  ];

  @override
  void dispose() {
    _saveCaption?.cancel();
    _uploads.setCaption(_caption.text);
    _caption.dispose();
    super.dispose();
  }

  /// Swiped away: back to Selected (with its edit), not deleted.
  Future<void> _setAside(UploadItem item) async {
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    await uploads.move([item.shotId], ItemStatus.selected);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('${item.name} moved to Selected'),
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => uploads.put(item)),
      ),
    );
  }

  Future<void> _reEdit(UploadItem item) async {
    final card = AppScope.of(context).card;
    CardFile? jpg;
    for (final s in card.shots) {
      if (s.id == item.shotId) jpg = s.jpg;
    }
    await openEditor(context, [EditTarget.fromItem(item, card: jpg)]);
  }

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return Scaffold(
      appBar: AppBar(title: const Text('Upload folder')),
      body: ListenableBuilder(
        listenable: uploads,
        builder: (context, _) {
          final items = uploads.queued;
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.only(bottom: navBarClearance),
              child: StatePanel(
                icon: Icons.outbox_rounded,
                title: 'Nothing to post yet',
                body:
                    'Edit a photo from the Gallery or from Selected and it lands here, ready for Instagram. '
                    'Swipe one away to set it aside in Selected.',
                actions: [
                  OutlinedButton.icon(
                    onPressed: () => HomeShell.go(context, HomeTab.selected),
                    icon: const Icon(Icons.favorite_border_rounded),
                    label: const Text('Open Selected'),
                  ),
                ],
              ),
            );
          }
          final picked = _picked.length;
          final all = picked == items.length;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${items.length} ${items.length == 1 ? 'PHOTO' : 'PHOTOS'} · POSTING ORDER · $picked TICKED',
                          style: sectionLabel,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          all ? _skipped.addAll(items.map((i) => i.shotId)) : _skipped.clear();
                        }),
                        child: Text(all ? 'Untick all' : 'Tick all'),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                sliver: SliverReorderableList(
                  itemCount: items.length,
                  onReorderItem: uploads.reorder,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return Dismissible(
                      key: ValueKey(item.shotId),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _setAside(item),
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(color: surfaceHigh, borderRadius: BorderRadius.circular(18)),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('To Selected', style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
                            SizedBox(width: 8),
                            Icon(Icons.favorite_rounded, color: accent),
                          ],
                        ),
                      ),
                      child: _UploadRow(
                        index: i,
                        item: item,
                        picked: !_skipped.contains(item.shotId),
                        onPick: () => setState(() {
                          if (!_skipped.remove(item.shotId)) _skipped.add(item.shotId);
                        }),
                        onEdit: () => _reEdit(item),
                      ),
                    );
                  },
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('CAPTION', style: sectionLabel),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _caption,
                        minLines: 3,
                        maxLines: 8,
                        maxLength: 2200, // Instagram's caption limit
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(hintText: 'Write a caption… #hashtags work too'),
                        onChanged: (v) {
                          _saveCaption?.cancel();
                          _saveCaption = Timer(const Duration(milliseconds: 600), () => uploads.setCaption(v));
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          );
        },
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: uploads,
        builder: (context, _) {
          if (uploads.queued.isEmpty) return const SizedBox.shrink();
          final picked = _picked, n = picked.length, left = uploads.queued.length - n;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (left > 0 && n > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '$left unticked ${left == 1 ? 'photo goes' : 'photos go'} back to Selected once you\'ve posted',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: n == 0
                        ? null
                        : () async {
                            _saveCaption?.cancel();
                            await uploads.setCaption(_caption.text);
                            if (context.mounted) await showPublishSheet(context, picked);
                          },
                    icon: const Icon(Icons.send_rounded),
                    label: Text(n == 0 ? 'Tick photos to publish' : 'Publish $n ${n == 1 ? 'photo' : 'photos'}'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({
    required this.index,
    required this.item,
    required this.picked,
    required this.onPick,
    required this.onEdit,
  });
  final int index;
  final UploadItem item;
  final bool picked; // ticked for publishing
  final VoidCallback onPick, onEdit;

  String get _summary {
    final p = item.params;
    final parts = <String>[
      if (p.aspect != AspectPreset.original) p.aspect.label,
      if (p.quarterTurns != 0 || p.straighten != 0) 'rotated',
      if (p.filter != 'original') presetById(p.filter).label,
      if (p.height > 0) 'taller',
      if (p.height < 0) 'shorter',
      if (p.slims.any((s) => s.amount > 0)) 'slimmer',
      if (p.slims.any((s) => s.amount < 0)) 'wider',
      if (p.hips > 0) 'hips',
      if (p.legs > 0) 'slimmer legs',
      if (p.brightness != 0 || p.contrast != 0 || p.saturation != 0 || p.warmth != 0) 'adjusted',
    ];
    return parts.isEmpty ? 'No changes' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: picked ? 'Leave for later' : 'Publish this one',
                onPressed: onPick,
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Icon(
                    picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    key: ValueKey(picked),
                    color: picked ? accent : muted,
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: picked ? 1 : 0.45,
                child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: Image.file(
                    File(item.previewPath),
                    fit: BoxFit.cover,
                    cacheWidth: 216,
                    errorBuilder: (_, _, _) => const ColoredBox(color: surfaceHigh),
                  ),
                ),
              ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                      '${shortDay(item.taken)} · ${clock(item.taken)}',
                      style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: accent, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              IconButton(tooltip: 'Edit again', onPressed: onEdit, icon: const Icon(Icons.edit_rounded, color: ink)),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.drag_indicator_rounded, color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
