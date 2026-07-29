import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/shared/formatters/invite_code.dart';

void main() {
  test('pairing code helper normalizes, validates and formats input', () {
    expect(normalizePairingCode(' 12-34 56x78 '), '12345678');
    expect(pairingCodeDigits(' 12345678 '), '12345678');
    expect(pairingCodeDigits('1234'), isNull);
    expect(isPairingCode(' 12345678 '), isTrue);
    expect(isPairingCode('1234'), isFalse);
    expect(
      firstPairingCode(const ['abc', '12-34', '12345678', '99999999']),
      '12345678',
    );
    expect(firstPairingCode(const ['abc', '12-34']), isNull);
    expect(formatInviteCode('12-345678'), '1234 5678');
  });
}
