import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../edit/filters.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_screen.dart';
import 'publish_screen.dart';
import 'setup_screen.dart';

/// The Upload folder: edited photos in posting order (drag to reorder, swipe
/// to remove, tap to edit again), the caption, and the way out to Instagram.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  late final _uploads = AppScope.of(context).uploads;
  late final _caption = TextEditingController(text: _uploads.caption);
  Timer? _saveCaption;

  @override
  void dispose() {
    _saveCaption?.cancel();
    _uploads.setCaption(_caption.text);
    _caption.dispose();
    super.dispose();
  }

  Future<void> _remove(UploadItem item) async {
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    await uploads.remove(item.shotId);
    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text('${item.name} removed from the Upload folder'),
        action: SnackBarAction(label: 'Undo', onPressed: () => uploads.put(item)),
      ),
    );
    controller.closed.then((_) => uploads.purge(item));
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
      appBar: AppBar(
        title: const Text('Upload folder'),
        actions: [
          IconButton(
            tooltip: 'Instagram & Facebook',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetupScreen())),
            icon: const Icon(Icons.manage_accounts_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: uploads,
        builder: (context, _) {
          final items = uploads.queued;
          if (items.isEmpty) {
            return const StatePanel(
              icon: Icons.outbox_rounded,
              title: 'Nothing to post yet',
              body:
                  'Open a photo from the card and tap "Edit before upload". '
                  'Edited photos land here, ready for Instagram.',
            );
          }
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    '${items.length} ${items.length == 1 ? 'PHOTO' : 'PHOTOS'} · POSTING ORDER',
                    style: sectionLabel,
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
                      onDismissed: (_) => _remove(item),
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(color: negative, borderRadius: BorderRadius.circular(18)),
                        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                      ),
                      child: _UploadRow(index: i, item: item, onTap: () => _reEdit(item)),
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
          final n = uploads.queued.length;
          if (n == 0) return const SizedBox.shrink();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: () async {
                  _saveCaption?.cancel();
                  await uploads.setCaption(_caption.text);
                  if (context.mounted) await showPublishSheet(context);
                },
                icon: const Icon(Icons.send_rounded),
                label: Text('Publish $n ${n == 1 ? 'photo' : 'photos'}'),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.index, required this.item, required this.onTap});
  final int index;
  final UploadItem item;
  final VoidCallback onTap;

  String get _summary {
    final p = item.params;
    final parts = <String>[
      if (p.aspect != AspectPreset.original) p.aspect.label,
      if (p.quarterTurns != 0 || p.straighten != 0) 'rotated',
      if (p.filter != 'original') presetById(p.filter).label,
      if (p.height > 0) 'stretched',
      if (p.slim > 0) 'slimmer',
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
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: Image.file(
                    File(item.exportPath),
                    fit: BoxFit.cover,
                    cacheWidth: 216,
                    errorBuilder: (_, _, _) => const ColoredBox(color: surfaceHigh),
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
