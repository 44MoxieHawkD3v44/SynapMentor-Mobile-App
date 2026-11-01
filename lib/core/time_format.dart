// Formatting for "wall clock" times: DateTimes whose fields already hold the
// local time in the user's chosen timezone (stored as UTC so the device's own
// zone never shifts them).

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String formatClock(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

String formatDay(DateTime t) => '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} ${t.year}';

String weekdayShort(DateTime t) => _weekdays[t.weekday - 1];

String weekdayName(int weekday) =>
    const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][weekday - 1];

String formatHour(int hour) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h ${hour < 12 || hour == 24 ? 'AM' : 'PM'}';
}

/// How long ago a device-local [t] was: "Just now", "5 min ago", "3 h ago",
/// then the date and time.
String relativeTime(DateTime t) {
  final ago = DateTime.now().difference(t);
  if (ago.inMinutes < 1) return 'Just now';
  if (ago.inHours < 1) return '${ago.inMinutes} min ago';
  if (ago.inDays < 1) return '${ago.inHours} h ago';
  return '${t.day} ${_months[t.month - 1]} ${t.year}, ${formatClock(t)}';
}
