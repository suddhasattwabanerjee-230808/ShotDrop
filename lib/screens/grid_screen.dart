import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../date_filter.dart';
import '../models.dart';
import '../stores.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_screen.dart';
import 'home_shell.dart';
import 'viewer_screen.dart';

enum Gallery { card, phone }

/// A gallery: every shot on the card (the SD Card Gallery) or every photo on
/// the phone (the Phone Gallery), newest first, by day. Tap to view,
/// long-press to pick several, then add them to Selected or edit them
/// straight into the Upload folder. ♡ marks the ones in Selected.
class GridScreen extends StatefulWidget {
  const GridScreen({super.key, this.gallery = Gallery.card});
  final Gallery gallery;

  @override
  State<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends State<GridScreen> {
  final _selected = <String>{}; // CardShot.id
  var _dates = DateFilter.all;

  /// The date filter's choices; Pick Dates… opens the calendar.
  Future<void> _pickDates(List<CardShot> all) async {
    final picked = await showModalBottomSheet<DatePreset>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Show Photos From', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            for (final p in DatePreset.values)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(p == DatePreset.custom ? Icons.date_range_rounded : Icons.event_rounded),
                title: Text(
                  p == DatePreset.custom && _dates.preset == DatePreset.custom ? _dates.label : p.label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: _dates.preset == p ? const Icon(Icons.check_rounded, color: accent) : null,
                onTap: () => Navigator.pop(context, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked != DatePreset.custom) return setState(() => _dates = DateFilter.preset(picked));
    final now = DateTime.now();
    final oldest = all.isEmpty ? now : all.last.taken;
    final newest = all.isEmpty ? now : all.first.taken;
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(oldest.year, oldest.month, oldest.day),
      lastDate: newest.isAfter(now) ? newest : now,
      initialDateRange: _dates.preset == DatePreset.custom ? DateTimeRange(start: _dates.first!, end: _dates.last!) : null,
      helpText: 'Show Photos From',
      saveText: 'Show',
    );
    if (range != null && mounted) setState(() => _dates = DateFilter.range(range.start, range.end));
  }

  bool get _selecting => _selected.isNotEmpty;

  // Picking photos: the floating bar makes way for the picking actions.
  void _syncBar() => HomeShell.hidden.value = _selecting;

  void _clear() {
    setState(_selected.clear);
    _syncBar();
  }

  @override
  void dispose() {
    HomeShell.hidden.value = false;
    super.dispose();
  }

  void _toggle(CardShot s) {
    if (!s.editable) {
      _rawOnly();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(s.id) ? _selected.remove(s.id) : _selected.add(s.id));
    _syncBar();
  }

  void _toggleDay(List<CardShot> day) {
    final ids = [
      for (final s in day)
        if (s.editable) s.id,
    ];
    setState(() => ids.every(_selected.contains) ? _selected.removeAll(ids) : _selected.addAll(ids));
    _syncBar();
  }

  Future<void> _addToSelected(List<CardShot> shots) async {
    final picked = [
      for (final s in shots)
        if (_selected.contains(s.id)) s,
    ];
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    _clear();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        persist: false,
        content: Text(picked.length == 1 ? 'Adding To Selected…' : 'Adding ${picked.length} Photos To Selected…'),
        action: SnackBarAction(label: 'View', onPressed: () => HomeShell.go(context, HomeTab.selected)),
      ),
    );
    await uploads.select(picked);
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
    _clear();
    if (saved > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          persist: false,
          content: Text(saved == 1 ? 'Added To The Upload Folder' : '$saved Photos Added To The Upload Folder'),
          action: SnackBarAction(label: 'Open', onPressed: () => HomeShell.go(context, HomeTab.upload)),
        ),
      );
    }
  }

  ShotSource get _source {
    final scope = AppScope.of(context);
    return widget.gallery == Gallery.card ? scope.card : scope.phone;
  }

  // The list changes under this screen (rescan, another card, new photos on
  // the phone), so it listens itself: the home screen hands it over as a const widget.
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _source, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final scope = AppScope.of(context);
    final phone = widget.gallery == Gallery.phone;
    final all = _source.shots;
    final shots = _dates.isAll ? all : [for (final s in all) if (_dates.contains(s.taken)) s];
    _selected.retainAll({for (final s in shots) s.id});
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
        if (!didPop) _clear();
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: _clear),
                title: Text('${_selected.length} selected'),
                backgroundColor: surface,
              )
            : AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(phone ? 'Phone Gallery' : 'SD Card Gallery'),
                    Text(
                      [
                        _dates.isAll ? '${shots.length}' : '${shots.length} of ${all.length}',
                        phone ? (all.length == 1 ? 'photo' : 'photos') : 'shots',
                        if (!phone && rawCount > 0) '· $rawCount with RAW',
                        if (phone && scope.phone.partial) '· only the ones you allowed',
                      ].join(' '),
                      style: const TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                actions: [
                  if (_dates.isAll)
                    IconButton(
                      tooltip: 'Filter By Date',
                      onPressed: () => _pickDates(all),
                      icon: const Icon(Icons.calendar_month_rounded),
                    )
                  else
                    _DateChip(
                      label: _dates.label,
                      onTap: () => _pickDates(all),
                      onClear: () => setState(() => _dates = DateFilter.all),
                    ),
                  if (phone && scope.phone.partial)
                    TextButton(onPressed: scope.phone.requestAccess, child: const Text('Allow All')),
                  IconButton(
                    tooltip: phone ? 'Refresh' : 'Rescan The Card',
                    onPressed: _source.refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
                bottom: GalleryToggle(current: widget.gallery),
              ),
        body: shots.isEmpty && !_dates.isAll
            ? StatePanel(
                icon: Icons.event_busy_rounded,
                title: 'No Photos On These Dates',
                body: '${_dates.label}: nothing ${phone ? 'on the phone' : 'on the card'}.',
                actions: [
                  FilledButton(onPressed: () => setState(() => _dates = DateFilter.all), child: const Text('Show All Dates')),
                  TextButton(onPressed: () => _pickDates(all), child: const Text('Pick Other Dates')),
                ],
              )
            : shots.isEmpty
            ? StatePanel(
                icon: Icons.photo_library_outlined,
                title: phone ? 'No Photos On The Phone' : 'No Photos On The Card',
                body: phone
                    ? 'Photos taken or saved on the phone show up here.'
                    : 'The card\'s DCIM folder has no JPG or NEF files.',
              )
            : RefreshIndicator(
                onRefresh: _source.refresh,
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
                                kept: scope.uploads.isSelected(s.id),
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
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _addToSelected(shots),
                            icon: const Icon(Icons.favorite_border_rounded),
                            label: const Text('To Selected'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _editSelected(shots),
                            icon: const Icon(Icons.auto_fix_high_rounded),
                            label: Text('Edit (${_selected.length})'),
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
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

/// The date filter in use, in the title bar: tap to change it, ✕ to show all dates.
class _DateChip extends StatelessWidget {
  const _DateChip({required this.label, required this.onTap, required this.onClear});
  final String label;
  final VoidCallback onTap, onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Material(
      color: accent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event_rounded, size: 16, color: onAccent),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: onAccent, fontWeight: FontWeight.w800, fontSize: 13)),
              IconButton(
                tooltip: 'Show All Dates',
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18, color: onAccent),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// SD Card | Phone, under a gallery's title: switches to the other gallery.
class GalleryToggle extends StatelessWidget implements PreferredSizeWidget {
  const GalleryToggle({super.key, required this.current});
  final Gallery current;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: SizedBox(
      width: double.infinity,
      child: SegmentedButton<Gallery>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: Gallery.card, icon: Icon(Icons.sd_card_rounded), label: Text('SD Card')),
          ButtonSegment(value: Gallery.phone, icon: Icon(Icons.smartphone_rounded), label: Text('Phone')),
        ],
        selected: {current},
        onSelectionChanged: (s) => HomeShell.go(context, s.single == Gallery.card ? HomeTab.gallery : HomeTab.phone),
      ),
    ),
  );
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
          TextButton(onPressed: onToggle, child: Text(allSelected ? 'Clear Day' : 'Select Day'))
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
    required this.kept,
    required this.posted,
    required this.onTap,
    required this.onLongPress,
  });

  final CardShot shot;
  final bool selected, selecting, queued, kept, posted; // kept: in Selected
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
          else if (kept)
            const Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'SELECTED', icon: Icons.favorite_rounded, color: accent, fg: onAccent),
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
