/// Which days a gallery shows: all of them, a preset counted back from today,
/// one date, or a range of days picked on the calendar (both ends included).
enum DatePreset {
  all('All Dates'),
  today('Today'),
  yesterday('Yesterday'),
  week('Last 7 Days'),
  month('Last 30 Days'),
  day('One Date'),
  range('Date Range');

  const DatePreset(this.label);
  final String label;

  /// One Date and Date Range open the calendar.
  bool get picked => this == day || this == range;
}

/// Which part of the day: any time, a named part, or a range of times picked
/// on the clock. Night runs past midnight (9 PM to 5 AM).
enum DayTime {
  any('Any Time', 0, 0),
  morning('Morning', 5 * 60, 12 * 60),
  afternoon('Afternoon', 12 * 60, 17 * 60),
  evening('Evening', 17 * 60, 21 * 60),
  night('Night', 21 * 60, 5 * 60),
  range('Time Range', 0, 0);

  const DayTime(this.label, this.from, this.to);
  final String label;
  final int from, to; // minutes after midnight, [from, to); named parts only

  /// "5 AM–12 PM" for the named parts.
  String get hours => '${_hour(from)}–${_hour(to)}';
}

String _hour(int minutes) {
  final h = minutes ~/ 60 % 24, m = minutes % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'} ${h < 12 ? 'AM' : 'PM'}';
}

class DateFilter {
  const DateFilter._(this.preset, {this.first, this.last, this.time = DayTime.any, this.from = 0, this.to = 0});

  static const all = DateFilter._(DatePreset.all);

  /// A preset counted back from today (not [DatePreset.day] or [DatePreset.range]).
  factory DateFilter.preset(DatePreset p) => DateFilter._(p);

  /// The one day of [date].
  factory DateFilter.day(DateTime date) => DateFilter._(DatePreset.day, first: _day(date), last: _day(date));

  /// From the day of [first] to the day of [last], both included.
  factory DateFilter.range(DateTime first, DateTime last) =>
      DateFilter._(DatePreset.range, first: _day(first), last: _day(last.isBefore(first) ? first : last));

  final DatePreset preset;
  final DateTime? first, last; // One Date and Date Range only: whole days
  final DayTime time;
  final int from, to; // Time Range only: minutes after midnight, both ends included

  bool get isAll => preset == DatePreset.all && time == DayTime.any;

  /// The same days, at [time] ([from] and [to], minutes after midnight, for a Time Range).
  DateFilter at(DayTime time, {int from = 0, int to = 0}) =>
      DateFilter._(preset, first: first, last: last, time: time, from: from, to: to);

  /// Other days, at the same time of day.
  DateFilter onDays(DateFilter days) =>
      DateFilter._(days.preset, first: days.first, last: days.last, time: time, from: from, to: to);

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  /// The days shown, as [start, end) on [now]'s calendar; null for all.
  (DateTime, DateTime)? span(DateTime now) {
    final today = _day(now);
    DateTime back(int days) => DateTime(today.year, today.month, today.day - days);
    final tomorrow = back(-1);
    return switch (preset) {
      DatePreset.all => null,
      DatePreset.today => (today, tomorrow),
      DatePreset.yesterday => (back(1), today),
      DatePreset.week => (back(6), tomorrow),
      DatePreset.month => (back(29), tomorrow),
      DatePreset.day || DatePreset.range => (first!, DateTime(last!.year, last!.month, last!.day + 1)),
    };
  }

  bool _atTime(DateTime t) {
    if (time == DayTime.any) return true;
    final m = t.hour * 60 + t.minute;
    final picked = time == DayTime.range; // its end minute counts
    final a = picked ? from : time.from, b = picked ? to : time.to;
    final beforeEnd = picked ? m <= b : m < b;
    // A range that runs past midnight (Night, or 10 PM to 2 AM) wraps round.
    return a <= b ? m >= a && beforeEnd : m >= a || beforeEnd;
  }

  bool contains(DateTime t, {DateTime? now}) {
    final s = span(now ?? DateTime.now());
    return (s == null || (!t.isBefore(s.$1) && t.isBefore(s.$2))) && _atTime(t);
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Last 7 Days", "3 Oct", "3–9 Oct", "28 Sep – 4 Oct", "28 Dec 2025 – 3 Jan".
  String get daysLabel {
    if (!preset.picked) return preset.label;
    final a = first!, b = last!;
    String day(DateTime d, {bool year = false}) => '${d.day} ${_months[d.month - 1]}${year ? ' ${d.year}' : ''}';
    if (a == b) return day(a, year: a.year != DateTime.now().year);
    if (a.year != b.year) return '${day(a, year: true)} – ${day(b)}';
    if (a.month == b.month) return '${a.day}–${day(b)}';
    return '${day(a)} – ${day(b)}';
  }

  /// "Any Time", "Morning", "6 PM–9:30 PM".
  String get timeLabel => time == DayTime.range ? '${_hour(from)}–${_hour(to)}' : time.label;

  /// "3 Oct · Morning", "Last 7 Days", "Night" (any day).
  String get label => [
    if (preset != DatePreset.all || time == DayTime.any) daysLabel,
    if (time != DayTime.any) timeLabel,
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is DateFilter &&
      other.preset == preset &&
      other.first == first &&
      other.last == last &&
      other.time == time &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(preset, first, last, time, from, to);
}
