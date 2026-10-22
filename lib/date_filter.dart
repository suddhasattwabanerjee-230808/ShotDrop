/// Which days a gallery shows: all of them, a preset counted back from today,
/// or days picked on the calendar (both ends included).
enum DatePreset {
  all('All Dates'),
  today('Today'),
  yesterday('Yesterday'),
  week('Last 7 Days'),
  month('Last 30 Days'),
  custom('Pick Dates…');

  const DatePreset(this.label);
  final String label;
}

class DateFilter {
  const DateFilter._(this.preset, [this.first, this.last]);

  static const all = DateFilter._(DatePreset.all);

  /// A preset ([DatePreset.custom] needs [DateFilter.range]).
  factory DateFilter.preset(DatePreset p) => DateFilter._(p);

  /// From the day of [first] to the day of [last], both included.
  factory DateFilter.range(DateTime first, DateTime last) =>
      DateFilter._(DatePreset.custom, _day(first), _day(last.isBefore(first) ? first : last));

  final DatePreset preset;
  final DateTime? first, last; // custom only: whole days

  bool get isAll => preset == DatePreset.all;

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
      DatePreset.custom => (first!, DateTime(last!.year, last!.month, last!.day + 1)),
    };
  }

  bool contains(DateTime t, {DateTime? now}) {
    final s = span(now ?? DateTime.now());
    return s == null || (!t.isBefore(s.$1) && t.isBefore(s.$2));
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Last 7 Days", "3 Oct", "3–9 Oct", "28 Sep – 4 Oct", "28 Dec 2025 – 3 Jan".
  String get label {
    if (preset != DatePreset.custom) return preset.label;
    final a = first!, b = last!;
    String day(DateTime d, {bool year = false}) => '${d.day} ${_months[d.month - 1]}${year ? ' ${d.year}' : ''}';
    if (a == b) return day(a, year: a.year != DateTime.now().year);
    if (a.year != b.year) return '${day(a, year: true)} – ${day(b)}';
    if (a.month == b.month) return '${a.day}–${day(b)}';
    return '${day(a)} – ${day(b)}';
  }

  @override
  bool operator ==(Object other) =>
      other is DateFilter && other.preset == preset && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(preset, first, last);
}
