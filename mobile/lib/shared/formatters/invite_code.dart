import 'package:flutter/services.dart';

String normalizePairingCode(String value) =>
    value.replaceAll(RegExp(r'\D'), '');

String? pairingCodeDigits(String value) {
  final digits = normalizePairingCode(value);
  return digits.length == 8 ? digits : null;
}

bool isPairingCode(String value) => pairingCodeDigits(value) != null;

String? firstPairingCode(Iterable<String?> values) {
  for (final value in values) {
    if (value == null) continue;
    final digits = pairingCodeDigits(value);
    if (digits != null) return digits;
  }
  return null;
}

String formatInviteCode(String code) {
  final digits = normalizePairingCode(code);
  return RegExp(
    r'.{1,4}',
  ).allMatches(digits).map((match) => match.group(0)!).join(' ');
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
    final digits = normalizePairingCode(newValue.text);
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    final formatted = formatInviteCode(limited);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
