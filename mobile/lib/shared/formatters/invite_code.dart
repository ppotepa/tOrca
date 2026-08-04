import 'package:flutter/services.dart';

const _pairingCodeLength = 8;

String normalizePairingCode(String value) =>
    value.trim().replaceAll(RegExp(r'\s'), '');

String? pairingCode(String value) {
  final normalized = normalizePairingCode(value);
  if (normalized.length != _pairingCodeLength ||
      !RegExp(r'^\d{8}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

bool isPairingCode(String value) => pairingCode(value) != null;

String? firstPairingCode(Iterable<String?> values) {
  for (final value in values) {
    if (value == null) continue;
    final code = pairingCode(value);
    if (code != null) return code;
  }
  return null;
}

String formatInviteCode(String code) {
  final normalized = normalizePairingCode(code);
  if (normalized.length <= 4) return normalized;
  return '${normalized.substring(0, 4)} ${normalized.substring(4)}';
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
    final rawDigits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final digits = rawDigits.substring(
      0,
      rawDigits.length > _pairingCodeLength
          ? _pairingCodeLength
          : rawDigits.length,
    );
    final formatted = formatInviteCode(digits);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
