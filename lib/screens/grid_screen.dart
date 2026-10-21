import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'card_screen.dart';
import 'editor_screen.dart';
import 'viewer_screen.dart';

/// Every shot on the card, newest first, by day. Tap to view, long-press to
/// start picking several for "Edit before upload".
class GridScreen extends StatefulWidget {
  const GridScreen({super.key});

  @override
  State<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends State<GridScreen> {
  final _selected = <String>{}; // CardShot.id

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(CardShot s) {
    if (!s.editable) {
      _rawOnly();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(s.id) ? _selected.remove(s.id) : _selected.add(s.id));
  }

  void _toggleDay(List<CardShot> day) {
    final ids = [
      for (final s in day)
        if (s.editable) s.id,
    ];
    setState(() => ids.every(_selected.contains) ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  void _rawOnly() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('This shot is RAW only (no JPEG), so it can\'t be edited here. Shoot RAW+JPEG to edit it.'),
    ),
  );

  Future<void> _editSelected(List<CardShot> shots) async {
    final picked = [
      for (final s in shots)
        if (_selected.contains(s.id)) EditTarget.fromShot(s),
    ];
    final saved = await openEditor(context, picked);
    if (!mounted) return;
    setState(_selected.clear);
    if (saved > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(saved == 1 ? 'Added to the Upload folder' : '$saved photos added to the Upload folder')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final shots = scope.card.shots;
    final days = <List<CardShot>>[];
    for (final s in shots) {
      final t = s.taken;
      if (days.isEmpty || !_sameDay(days.last.first.taken, t)) days.add([]);
      days.last.add(s);
    }
    final rawCount = shots.where((s) => s.hasRaw).length;

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(_selected.clear)),
                title: Text('${_selected.length} selected'),
                backgroundColor: surface,
              )
            : AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Camera card'),
                    Text(
                      '${shots.length} shots${rawCount > 0 ? ' · $rawCount with RAW' : ''}',
                      style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                actions: [
                  const UploadFolderButton(),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rescan') scope.card.refresh();
                      if (v == 'folder') scope.card.pickFolder();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rescan', child: Text('Rescan the card')),
                      PopupMenuItem(value: 'folder', child: Text('Choose another folder')),
                    ],
                  ),
                ],
              ),
        body: shots.isEmpty
            ? const StatePanel(
                icon: Icons.photo_library_outlined,
                title: 'No photos here',
                body: 'This folder has no JPG or NEF files. Pick the card\'s DCIM folder from the menu.',
              )
            : RefreshIndicator(
                onRefresh: scope.card.refresh,
                child: ListenableBuilder(
                  listenable: scope.uploads,
                  builder: (context, _) => CustomScrollView(
                    slivers: [
                      for (final day in days) ...[
                        SliverToBoxAdapter(
                          child: _DayHeader(
                            day: day,
                            selecting: _selecting,
                            allSelected: day.where((s) => s.editable).every((s) => _selected.contains(s.id)),
                            onToggle: () => _toggleDay(day),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            ),
                            delegate: SliverChildBuilderDelegate(childCount: day.length, (context, i) {
                              final s = day[i];
                              return _Tile(
                                shot: s,
                                selected: _selected.contains(s.id),
                                selecting: _selecting,
                                queued: scope.uploads.contains(s.id),
                                posted: scope.uploads.isPublished(s.id),
                                onTap: () => _selecting ? _toggle(s) : openViewer(context, shots, shots.indexOf(s)),
                                onLongPress: () => _toggle(s),
                              );
                            }),
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                    ],
                  ),
                ),
              ),
        bottomNavigationBar: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _selecting
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: FilledButton.icon(
                      onPressed: () => _editSelected(shots),
                      icon: const Icon(Icons.auto_fix_high_rounded),
                      label: Text('Edit before upload (${_selected.length})'),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.selecting, required this.allSelected, required this.onToggle});

  final List<CardShot> day;
  final bool selecting, allSelected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
    child: Row(
      children: [
        Text(shortDay(day.first.taken), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Text(
          '${day.length}',
          style: const TextStyle(fontSize: 13, color: muted, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (selecting)
          TextButton(onPressed: onToggle, child: Text(allSelected ? 'Clear day' : 'Select day'))
        else
          const SizedBox(height: 40),
      ],
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.shot,
    required this.selected,
    required this.selecting,
    required this.queued,
    required this.posted,
    required this.onTap,
    required this.onLongPress,
  });

  final CardShot shot;
  final bool selected, selecting, queued, posted;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    onLongPress: onLongPress,
    child: Hero(
      tag: 'shot-${shot.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedPadding(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.all(selected ? 10 : 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(selected ? 10 : 2),
              child: CardImage(file: shot.primary, maxEdge: 360),
            ),
          ),
          if (!shot.editable) const ColoredBox(color: Color(0x66000000)),
          Positioned(
            top: 6,
            right: 6,
            child: shot.hasRaw ? PhotoBadge(label: shot.editable ? 'RAW' : 'RAW ONLY') : const SizedBox.shrink(),
          ),
          if (queued)
            const Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'READY', icon: Icons.check_rounded, color: positive, fg: Color(0xFF06210F)),
            )
          else if (posted)
            const Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'POSTED', icon: Icons.send_rounded),
            ),
          if (selecting)
            Positioned(
              top: 6,
              left: 6,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? accent : const Color(0x66000000),
                  border: Border.all(color: selected ? accent : Colors.white, width: 2),
                ),
                child: selected ? const Icon(Icons.check_rounded, size: 16, color: onAccent) : null,
              ),
            ),
        ],
      ),
    ),
  );
}
