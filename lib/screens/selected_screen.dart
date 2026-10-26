import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../share_channel.dart';
import '../sharing.dart';
import '../theme.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'editor_screen.dart';
import 'home_shell.dart';

/// Selected: the shortlist. Photos picked from the card (♡ in the viewer, or
/// "Add to Selected" in the Gallery), and photos set aside from the Upload
/// folder to post later, with their edits. ShotDrop keeps its own copies, so
/// they're here with the card unplugged. Tap one to edit it into the Upload
/// folder; long-press to pick several.
class SelectedScreen extends StatefulWidget {
  const SelectedScreen({super.key});

  @override
  State<SelectedScreen> createState() => _SelectedScreenState();
}

class _SelectedScreenState extends State<SelectedScreen> {
  final _picked = <String>{}; // shotIds

  bool get _picking => _picked.isNotEmpty;

  Future<void> _edit(List<UploadItem> items) async {
    final card = AppScope.of(context).card;
    final targets = [
      for (final i in items) EditTarget.fromItem(i, card: card.shots.where((s) => s.id == i.shotId).firstOrNull?.jpg),
    ];
    final saved = await openEditor(context, targets);
    if (!mounted) return;
    setState(_picked.clear);
    if (saved > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          persist: false,
          content: Text(saved == 1 ? 'Moved To The Upload Folder' : '$saved Photos Moved To The Upload Folder'),
          action: SnackBarAction(label: 'Open', onPressed: () => HomeShell.go(context, HomeTab.upload)),
        ),
      );
    }
  }

  Future<void> _remove(List<UploadItem> items) async {
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    for (final i in items) {
      await uploads.remove(i.shotId);
    }
    setState(_picked.clear);
    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        persist: false,
        content: Text(items.length == 1 ? '${items.single.name} removed' : '${items.length} Photos Removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            for (final i in items) {
              await uploads.put(i);
            }
          },
        ),
      ),
    );
    controller.closed.then((_) => items.forEach(uploads.purge));
  }

  /// Android's share sheet (WhatsApp, Bluetooth, Drive, Messages…) with the
  /// picked photos: the edit where there is one, else the photo as kept.
  Future<void> _share(List<UploadItem> items) async {
    final messenger = ScaffoldMessenger.of(context);
    final paths = [
      for (final i in items)
        if (File(i.previewPath).existsSync()) i.previewPath,
    ];
    if (paths.isEmpty) return;
    HapticFeedback.selectionClick();
    final opened = await ShareChannel.instance.shareAny(paths).catchError((Object _) => false);
    if (!mounted) return;
    if (opened) {
      setState(_picked.clear);
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('No App On This Phone Can Take Photos')));
    }
  }

  void _toggle(UploadItem i) {
    HapticFeedback.selectionClick();
    setState(() => _picked.contains(i.shotId) ? _picked.remove(i.shotId) : _picked.add(i.shotId));
  }

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return ListenableBuilder(
      listenable: uploads,
      builder: (context, _) {
        final items = uploads.selected;
        _picked.retainAll({for (final i in items) i.shotId});
        final picked = [
          for (final i in items)
            if (_picked.contains(i.shotId)) i,
        ];
        final edited = items.where((i) => i.edited).length;
        return PopScope(
          canPop: !_picking,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(_picked.clear);
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: _picking
                ? AppBar(
                    backgroundColor: surface,
                    leading: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_picked.clear),
                    ),
                    title: Text('${picked.length} picked'),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _picked.addAll(items.map((i) => i.shotId))),
                        child: const Text('All'),
                      ),
                      IconButton(
                        tooltip: 'Save To Gallery',
                        onPressed: () => savePathsToGallery(
                          context,
                          [for (final i in picked) i.previewPath],
                          [for (final i in picked) '${i.name}_edit'],
                        ),
                        icon: const Icon(Icons.download_rounded),
                      ),
                      IconButton(
                        tooltip: 'Remove From Selected',
                        onPressed: () => _remove(picked),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  )
                : AppBar(
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Selected'),
                        Text(
                          items.isEmpty
                              ? 'Your Shortlist'
                              : '${items.length} ${items.length == 1 ? 'Photo' : 'Photos'}'
                                    '${edited > 0 ? ' · $edited Edited' : ''}',
                          style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    actions: const [ThemeToggle()],
                  ),
            body: CustomScrollView(
              slivers: [
                if (uploads.copying > 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Text(
                            'Copying ${uploads.copying} From The Card…',
                            style: TextStyle(color: muted, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (items.isEmpty && uploads.copying == 0)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: StatePanel(
                      icon: Icons.favorite_border_rounded,
                      title: 'Nothing Selected Yet',
                      body:
                          'Tap ♡ on a photo in the Gallery, or long-press a few and tap "Add to Selected". '
                          'They\'re kept here, even with the card unplugged, until you edit and post them. '
                          'Photos you didn\'t post from the Upload folder come back here too.',
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                      ),
                      delegate: SliverChildBuilderDelegate(childCount: items.length, (context, i) {
                        final item = items[i];
                        return _Tile(
                          item: item,
                          picking: _picking,
                          picked: _picked.contains(item.shotId),
                          onTap: () => _picking ? _toggle(item) : _edit([item]),
                          onLongPress: () => _toggle(item),
                        );
                      }),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: navBarClearance + 24)),
              ],
            ),
            bottomNavigationBar: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: _picking
                  ? SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _share(picked),
                                icon: const Icon(Icons.share_rounded),
                                label: const Text('Share'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => _edit(picked),
                                icon: const Icon(Icons.auto_fix_high_rounded),
                                label: Text('Edit (${picked.length})'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.picking,
    required this.picked,
    required this.onTap,
    required this.onLongPress,
  });

  final UploadItem item;
  final bool picking, picked;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    onLongPress: onLongPress,
    child: Stack(
      fit: StackFit.expand,
      children: [
        AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(picked ? 8 : 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(picked ? 18 : 14),
            child: Image.file(
              File(item.previewPath),
              fit: BoxFit.cover,
              cacheWidth: 360,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => ColoredBox(color: surfaceHigh),
            ),
          ),
        ),
        if (item.edited)
          const Positioned(
            left: 6,
            bottom: 6,
            child: PhotoBadge(label: 'EDITED', icon: Icons.auto_fix_high_rounded, color: Color(0xE68B5CF6)),
          ),
        if (picking)
          Positioned(
            top: 6,
            left: 6,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: picked ? accent : const Color(0x66000000),
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: picked ? const Icon(Icons.check_rounded, size: 17, color: onAccent) : null,
            ),
          ),
      ],
    ),
  );
}
