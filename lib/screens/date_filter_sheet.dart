import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../date_filter.dart';
import '../theme.dart';

/// The gallery filter: which days (a preset, One Date or a Date Range) and
/// which part of the day (Morning, Afternoon, Evening, Night or a Time
/// Range). The button counts the photos it'll show. Pops the [DateFilter].
class DateFilterSheet extends StatefulWidget {
  const DateFilterSheet({super.key, required this.initial, required this.taken});
  final DateFilter initial;
  final List<DateTime> taken; // every photo in the gallery, newest first

  @override
  State<DateFilterSheet> createState() => _DateFilterSheetState();
}

class _DateFilterSheetState extends State<DateFilterSheet> {
  late var _f = widget.initial;

  int get _count => widget.taken.where((t) => _f.contains(t)).length;

  DateTime get _now => DateTime.now();
  DateTime get _oldest {
    final t = widget.taken.isEmpty ? _now : widget.taken.last;
    return DateTime(t.year, t.month, t.day);
  }

  DateTime get _newest {
    final t = widget.taken.isEmpty ? _now : widget.taken.first;
    return t.isAfter(_now) ? t : _now;
  }

  void _set(DateFilter f) {
    HapticFeedback.selectionClick();
    setState(() => _f = f);
  }

  Future<void> _days(DatePreset p) async {
    if (!p.picked) return _set(_f.onDays(DateFilter.preset(p)));
    if (p == DatePreset.day) {
      final first = _oldest, last = _newest;
      var initial = _f.preset == DatePreset.day ? _f.first! : last;
      if (initial.isBefore(first)) initial = first;
      if (initial.isAfter(last)) initial = last;
      final day = await showDatePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDate: initial,
        helpText: 'Show Photos From',
        confirmText: 'Pick',
      );
      if (day != null && mounted) _set(_f.onDays(DateFilter.day(day)));
      return;
    }
    final range = await showDateRangePicker(
      context: context,
      firstDate: _oldest,
      lastDate: _newest,
      initialDateRange: _f.preset == DatePreset.range ? DateTimeRange(start: _f.first!, end: _f.last!) : null,
      helpText: 'Show Photos From',
      saveText: 'Pick',
    );
    if (range != null && mounted) _set(_f.onDays(DateFilter.range(range.start, range.end)));
  }

  Future<void> _time(DayTime t) async {
    if (t != DayTime.range) return _set(_f.at(t));
    final custom = _f.time == DayTime.range;
    TimeOfDay of(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);
    final from = await showTimePicker(
      context: context,
      initialTime: of(custom ? _f.from : 18 * 60),
      helpText: 'From',
      confirmText: 'Next',
    );
    if (from == null || !mounted) return;
    final to = await showTimePicker(
      context: context,
      initialTime: of(custom ? _f.to : (from.hour + 3) % 24 * 60 + from.minute),
      helpText: 'To',
      confirmText: 'Pick',
    );
    if (to == null || !mounted) return;
    _set(_f.at(DayTime.range, from: from.hour * 60 + from.minute, to: to.hour * 60 + to.minute));
  }

  static const _dayIcons = {DatePreset.day: Icons.event_rounded, DatePreset.range: Icons.date_range_rounded};

  static const _timeIcons = {
    DayTime.any: Icons.schedule_rounded,
    DayTime.morning: Icons.wb_twilight_rounded,
    DayTime.afternoon: Icons.light_mode_rounded,
    DayTime.evening: Icons.dark_mode_outlined,
    DayTime.night: Icons.bedtime_rounded,
    DayTime.range: Icons.more_time_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final count = _count;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Show Photos From', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 18),
            const Text('DAYS', style: sectionLabel),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in DatePreset.values)
                  ChoiceChip(
                    avatar: _dayIcons[p] == null
                        ? null
                        : Icon(_dayIcons[p], size: 16, color: _f.preset == p ? onAccent : muted),
                    showCheckmark: false,
                    label: Text(_f.preset == p && p.picked ? _f.daysLabel : '${p.label}${p.picked ? '…' : ''}'),
                    selected: _f.preset == p,
                    onSelected: (_) => _days(p),
                    labelStyle: TextStyle(fontWeight: FontWeight.w800, color: _f.preset == p ? onAccent : ink),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            const Text('TIME OF DAY', style: sectionLabel),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.25,
              children: [for (final t in DayTime.values) _timeTile(t)],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton(
                  onPressed: _f.isAll ? null : () => _set(DateFilter.all),
                  child: const Text('Reset'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: count == 0 && !_f.isAll ? null : () => Navigator.pop(context, _f),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: Text(
                        count == 0 ? 'No Photos Match' : 'Show $count ${count == 1 ? 'Photo' : 'Photos'}',
                        key: ValueKey(count),
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

  Widget _timeTile(DayTime t) {
    final on = _f.time == t;
    final fg = on ? onAccent : ink;
    final sub = switch (t) {
      DayTime.any => 'All Day',
      DayTime.range => on ? _f.timeLabel : 'Pick Times',
      _ => t.hours,
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _time(t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: on ? accent : surfaceHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? accent : line),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_timeIcons[t], size: 22, color: on ? onAccent : accent),
              const SizedBox(height: 6),
              Text(t.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: fg)),
              const SizedBox(height: 2),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: on ? onAccent : muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
