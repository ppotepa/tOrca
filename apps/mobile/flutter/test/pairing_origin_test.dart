import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

void main() {
  test('inbox pairing keeps an explicit inbox origin', () {
    final item = PairingItem.fromMap({
      'pairingId': 'pairing-inbox',
      'state': 'PENDING',
      'received': true,
      'availableActions': const ['ACCEPT', 'REJECT'],
    }, origin: PairingOrigin.inbox);

    expect(item.origin, PairingOrigin.inbox);
    expect(item.received, isTrue);
  });

  test('outbox pairing keeps an explicit outbox origin', () {
    final item = PairingItem.fromMap({
      'pairingId': 'pairing-outbox',
      'state': 'PENDING',
      'received': false,
      'availableActions': const ['CANCEL'],
    }, origin: PairingOrigin.outbox);

    expect(item.origin, PairingOrigin.outbox);
    expect(item.received, isFalse);
  });

  test('missing received flag fails closed for inbox/outbox routing', () {
    final item = PairingItem.fromMap({
      'pairingId': 'pairing-missing-origin',
      'state': 'PENDING',
    }, origin: PairingOrigin.unknown);

    expect(item.received, isFalse);
    expect(item.origin, PairingOrigin.unknown);
  });
}
