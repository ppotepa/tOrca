import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing workflow recovery is not implemented in Flutter', () {
    final lib = Directory('lib');
    final sources = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    const forbidden = <String>[
      'PairingRecoveryAppController',
      '_pairingWatchdog',
      '_schedulePairingSync',
      '_synchronizePairing',
      '_retryWelcomeProjectionIfNeeded',
      '_promoteTrustedPairingContacts',
      '_runTrustedContactPromotion',
      '_lastPairingSync',
      '_autoTrustInFlight',
      '_lastAutoOpenedContactId',
    ];

    for (final symbol in forbidden) {
      expect(
        sources.contains(symbol),
        isFalse,
        reason: '$symbol would reintroduce a Flutter-owned pairing workflow',
      );
    }

    expect(
      File('lib/app/pairing_recovery_app_controller.dart').existsSync(),
      isFalse,
    );
  });

  test('presentation controller does not schedule domain retry', () {
    final source = File(
      'lib/app/presentation_app_controller.dart',
    ).readAsStringSync();

    expect(source.contains('Timer.periodic'), isFalse);
    expect(source.contains('Future<void>.delayed'), isFalse);
    expect(source.contains('verifyContact(contact.id)'), isFalse);
    expect(source.contains('openOrStartConversation(contact)'), isFalse);
  });
}
