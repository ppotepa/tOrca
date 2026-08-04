import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/shared/formatters/invite_code.dart';

void main() {
  test('pairing code helper normalizes, validates and formats input', () {
    expect(
      normalizePairingCode(' Amber-birch cobalt-dawn-ember fjord '),
      'amber-birch-cobalt-dawn-ember-fjord',
    );
    expect(
      pairingCode('amber-birch-cobalt-dawn-ember-fjord'),
      'amber-birch-cobalt-dawn-ember-fjord',
    );
    expect(pairingCode('1234'), isNull);
    expect(isPairingCode('amber-birch-cobalt-dawn-ember-fjord'), isTrue);
    expect(isPairingCode('1234'), isFalse);
    expect(
      firstPairingCode(const ['abc', 'amber-birch-cobalt-dawn-ember-fjord']),
      'amber-birch-cobalt-dawn-ember-fjord',
    );
    expect(firstPairingCode(const ['abc', '12-34']), isNull);
    expect(formatInviteCode('amber-birch-cobalt-dawn-ember-fjord'),
        'amber birch cobalt dawn ember fjord');
  });
}
