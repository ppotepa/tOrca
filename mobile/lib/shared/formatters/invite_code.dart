import 'package:flutter/services.dart';

String normalizePairingCode(String value) =>
    value.trim().toLowerCase().split(RegExp(r'[\s-]+')).where((word) => word.isNotEmpty).join('-');

String? pairingCode(String value) {
  final words = normalizePairingCode(value).split('-');
  if (words.length != 6 ||
      words.any((word) => word.length < 3 || word.length > 12 ||
          !RegExp(r'^[a-z]+$').hasMatch(word))) {
    return null;
  }
  return words.join('-');
}

bool isPairingCode(String value) => pairingCode(value) != null;

String? firstPairingCode(Iterable<String?> values) {
  for (final value in values) {
    if (value == null) continue;
    final digits = pairingCode(value);
    if (digits != null) return digits;
  }
  return null;
}

String formatInviteCode(String code) {
  return normalizePairingCode(code).replaceAll('-', ' ');
}

String formatCountdown(int seconds) {
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

class PairingCodeInputFormatter extends TextInputFormatter {
  const PairingCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final words = newValue.text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s-]'), '')
        .split(RegExp(r'[\s-]+'))
        .where((word) => word.isNotEmpty)
        .take(6)
        .join('-');
    final formatted = formatInviteCode(words);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
