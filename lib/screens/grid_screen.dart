import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../date_filter.dart';
import '../faces.dart';
import '../models.dart';
import '../prefetch.dart';
import '../stores.dart';
import '../theme.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'date_filter_sheet.dart';
import 'editor_screen.dart';
import 'people_sheet.dart';
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
  String? _personId; // the People filter: Person.id

  /// The People filter, in a sheet of everyone found in this gallery.
  Future<void> _pickPerson(List<CardShot> all) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => PeopleSheet(shots: all, current: _personId),
    );
    if (picked != null && mounted) setState(() => _personId = picked);
  }

  /// The date and time-of-day filter, in a sheet that counts what it'll show.
  Future<void> _pickDates(List<CardShot> all) async {
    final picked = await showModalBottomSheet<DateFilter>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DateFilterSheet(initial: _dates, taken: [for (final s in all) s.taken]),
    );
    if (picked != null && mounted) setState(() => _dates = picked);
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
    // Picked photos are about to be edited or kept: start copying the first few off the card.
    if (_selected.contains(s.id) && _selected.length <= 6 && AppScope.of(context).uploads.byShot(s.id) == null) {
      SourcePrefetch.warm(s.jpg!);
    }
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
  // With someone picked, the faces too: their photos are still being found.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _personId == null ? _source : Listenable.merge([_source, FaceIndex.instance]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final scope = AppScope.of(context);
    final phone = widget.gallery == Gallery.phone;
    final all = _source.shots;
    final person = _personId == null ? null : FaceIndex.instance.person(_personId!);
    final filtered = !_dates.isAll || person != null;
    final shots = !filtered
        ? all
        : [
            for (final s in all)
              if (_dates.contains(s.taken) &&
                  (person == null || (s.jpg != null && person.photos.contains(FaceIndex.keyOf(s.jpg!)))))
                s,
          ];
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
        backgroundColor: Colors.transparent,
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
                        filtered ? '${shots.length} of ${all.length}' : '${shots.length}',
                        phone ? (all.length == 1 ? 'Photo' : 'Photos') : 'Shots',
                        if (!phone && rawCount > 0) '· $rawCount With RAW',
                        if (phone && scope.phone.partial) '· Only The Ones You Allowed',
                      ].join(' '),
                      style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
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
                  if (person == null)
                    IconButton(
                      tooltip: 'Filter By People',
                      onPressed: () => _pickPerson(all),
                      icon: const Icon(Icons.face_rounded),
                    )
                  else
                    _PersonChip(
                      person: person,
                      onTap: () => _pickPerson(all),
                      onClear: () => setState(() => _personId = null),
                    ),
                  if (phone && scope.phone.partial)
                    TextButton(onPressed: scope.phone.requestAccess, child: const Text('Allow All')),
                  // Filtered, the bar is short of room: pull down to refresh instead.
                  if (!filtered)
                    IconButton(
                      tooltip: phone ? 'Refresh' : 'Rescan The Card',
                      onPressed: _source.refresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  const ThemeToggle(),
                ],
                bottom: GalleryToggle(current: widget.gallery),
              ),
        body: shots.isEmpty && filtered
            ? StatePanel(
                icon: person != null ? Icons.face_retouching_off_rounded : Icons.event_busy_rounded,
                title: 'No Photos For This Filter',
                body: person != null && _dates.isAll
                    ? 'Nothing of this person ${phone ? 'on the phone' : 'on the card'}.'
                    : '${_dates.label}${person != null ? ', of this person' : ''}: '
                          'nothing ${phone ? 'on the phone' : 'on the card'}.',
                actions: [
                  FilledButton(
                    onPressed: () => setState(() {
                      _dates = DateFilter.all;
                      _personId = null;
                    }),
                    child: const Text('Show All Photos'),
                  ),
                  if (!_dates.isAll)
                    TextButton(onPressed: () => _pickDates(all), child: const Text('Change The Dates')),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
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
      shape: ChunkyBorder(borderRadius: BorderRadius.circular(20), depth: 3, lip: deeper(accent)),
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 116),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: onAccent, fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
              IconButton(
                tooltip: 'Clear The Filter',
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

/// The person picked in the People filter, in the title bar: their face, tap
/// to pick someone else, ✕ to show everyone.
class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.person, required this.onTap, required this.onClear});
  final Person person;
  final VoidCallback onTap, onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Material(
      color: grape,
      shape: ChunkyBorder(borderRadius: BorderRadius.circular(20), depth: 3, lip: deeper(grape)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                child: ClipOval(child: FaceAvatar(person: person)),
              ),
              IconButton(
                tooltip: 'Show Everyone',
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
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
  Widget build(BuildContext context) {
    // Each day gets a colour of the rainbow, by its date, so it keeps it.
    final d = day.first.taken;
    final colour = rainbow[(d.year * 372 + d.month * 31 + d.day) % rainbow.length];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 8, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: deeper(colour, 0.16), offset: const Offset(0, 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  shortDay(d),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: onFun(colour)),
                ),
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minWidth: 24),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: onFun(colour).withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${day.length}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: onFun(colour), fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
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
            padding: EdgeInsets.all(selected ? 8 : 0),
            child: Container(
              foregroundDecoration: selected
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: accent, width: 3),
                    )
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(selected ? 18 : 14),
                child: Upright(
                  file: shot.primary,
                  child: CardImage(file: shot.primary, maxEdge: 360),
                ),
              ),
            ),
          ),
          if (!shot.editable)
            DecoratedBox(
              decoration: BoxDecoration(color: const Color(0x66000000), borderRadius: BorderRadius.circular(14)),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: shot.hasRaw ? PhotoBadge(label: shot.editable ? 'RAW' : 'RAW ONLY') : const SizedBox.shrink(),
          ),
          if (queued)
            Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'READY', icon: Icons.check_rounded, color: grass, fg: const Color(0xFF06210F)),
            )
          else if (kept)
            Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'SELECTED', icon: Icons.favorite_rounded, color: accent, fg: onAccent),
            )
          else if (posted)
            const Positioned(
              left: 6,
              bottom: 6,
              child: PhotoBadge(label: 'POSTED', icon: Icons.send_rounded, color: Color(0xE66A45E8)),
            ),
          if (selecting)
            Positioned(
              top: 6,
              left: 6,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? accent : const Color(0x66000000),
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: selected ? const Icon(Icons.check_rounded, size: 17, color: onAccent) : null,
              ),
            ),
        ],
      ),
    ),
  );
}
