import 'package:intl/intl.dart';

import '../../locales/generated/app_localizations.dart';

String formatMessageTime(String raw, {String locale = 'pl'}) {
  final value = DateTime.tryParse(raw)?.toLocal();
  if (value == null) return '--:--';
  return DateFormat.Hm().format(value);
}

String formatMessageDay(String raw, {String locale = 'pl'}) {
  final value = DateTime.tryParse(raw)?.toLocal();
  if (value == null) return 'Nieznana data';
  try {
    return DateFormat('EEEE, d MMMM y', locale).format(value);
  } catch (_) {
    // Widget tests and lightweight hosts may not have loaded optional locale
    // data yet; keep the formatter usable until the app bootstrap completes.
    return DateFormat('yyyy-MM-dd').format(value);
  }
}

bool isSameMessageDay(String left, String right) {
  final a = DateTime.tryParse(left)?.toLocal();
  final b = DateTime.tryParse(right)?.toLocal();
  if (a == null || b == null) return false;
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String formatMessageDayOrTime(String raw, {String locale = 'pl'}) {
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
    return DateFormat.Hm().format(value);
  }
  return DateFormat('dd.MM.yyyy').format(value);
}

String formatRelativeTimestamp(
  String? raw,
  AppLocalizations l10n, {
  required String empty,
}) {
  final clean = raw?.trim() ?? '';
  if (clean.isEmpty) return empty;
  final numeric = int.tryParse(clean);
  final parsed = numeric == null
      ? DateTime.tryParse(clean)?.toLocal()
      : DateTime.fromMillisecondsSinceEpoch(
          numeric < 100000000000 ? numeric * 1000 : numeric,
        ).toLocal();
  if (parsed == null) return clean;
  final difference = DateTime.now().difference(parsed);
  if (difference.isNegative || difference.inMinutes < 1) {
    return l10n.timeJustNow;
  }
  if (difference.inMinutes < 60) {
    return l10n.timeMinutesAgo(difference.inMinutes);
  }
  if (difference.inHours < 24) {
    return l10n.timeHoursAgo(difference.inHours);
  }
  if (difference.inDays < 7) {
    return l10n.timeDaysAgo(difference.inDays);
  }
  return DateFormat('dd.MM.yyyy').format(parsed);
}
