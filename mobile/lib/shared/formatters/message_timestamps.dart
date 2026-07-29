String formatMessageTime(String raw) {
  final value = DateTime.tryParse(raw)?.toLocal();
  if (value == null) return '--:--';
  final h = value.hour.toString().padLeft(2, '0');
  final m = value.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String formatMessageDay(String raw) {
  final value = DateTime.tryParse(raw)?.toLocal();
  if (value == null) return 'Nieznana data';
  const weekday = [
    'poniedziałek',
    'wtorek',
    'środa',
    'czwartek',
    'piątek',
    'sobota',
    'niedziela',
  ];
  const month = [
    'stycznia',
    'lutego',
    'marca',
    'kwietnia',
    'maja',
    'czerwca',
    'lipca',
    'sierpnia',
    'września',
    'października',
    'listopada',
    'grudnia',
  ];
  return '${weekday[value.weekday - 1]}, ${value.day} ${month[value.month - 1]} ${value.year}';
}

bool isSameMessageDay(String left, String right) {
  final a = DateTime.tryParse(left)?.toLocal();
  final b = DateTime.tryParse(right)?.toLocal();
  if (a == null || b == null) return false;
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String formatMessageDayOrTime(String raw) {
  final value = DateTime.tryParse(raw)?.toLocal();
  if (value == null) return '';
  final now = DateTime.now();
  final diff = now.difference(value);
  if (diff < const Duration(minutes: 1)) return 'teraz';
  if (diff < const Duration(hours: 1)) return '${diff.inMinutes} min temu';
  if (diff < const Duration(hours: 6)) return '${diff.inHours} h temu';
  if (value.day == now.day &&
      value.month == now.month &&
      value.year == now.year) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  final day = value.day.toString().padLeft(2, '0');
  final month = value.month.toString().padLeft(2, '0');
  return '$day.$month.${value.year}';
}
