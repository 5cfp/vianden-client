/// Small date/time formatting helpers (local time, 24-hour clock).
library;

String hourMinute(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

/// "Today", "Yesterday", or a date like "4 Oct 2026", for day separators.
String dayLabel(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final day = _dateOnly(l);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

/// Short time for the room list: "18:41" today, "Mon" this week, "4 Oct" older.
String shortWhen(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final days = _dateOnly(n).difference(_dateOnly(l)).inDays;
  if (days == 0) return hourMinute(l);
  if (days < 7) return _weekdays[l.weekday - 1];
  return '${l.day} ${_months[l.month - 1]}';
}

bool sameDay(DateTime a, DateTime b) =>
    _dateOnly(a.toLocal()) == _dateOnly(b.toLocal());

DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);
String _two(int n) => n.toString().padLeft(2, '0');

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
