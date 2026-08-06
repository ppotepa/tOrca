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
      '_maybeAutoPairTorka',
      '_runTorkaWatchdogTick',
      '_ensureTorkaWatchdog',
      'debugTorkaPairingCodeOverride',
      'debugTorkaWatchdogIntervalOverride',
      'debugTorkaWatchdogMaxAttemptsOverride',
      'refreshPairingAndApplication',
      'forcePairing',
      'allowAutoTorka',
      'includePairing',
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

  test('repository requires one authoritative application projection', () {
    final source = File(
      'lib/core/runtime/runtime_repository.dart',
    ).readAsStringSync();

    expect(source, contains('_requireProjectionProvider'));
    expect(source, contains('schema 2 is required'));
    expect(source.contains('_runtime.listPairings()'), isFalse);
    expect(source.contains('refreshPairingAndApplication'), isFalse);
    expect(source.contains('includePairing'), isFalse);
  });

  test('application controller does not schedule pairing recovery', () {
    final sources = <String>[
      File('lib/app/application_controller.dart').readAsStringSync(),
      File('lib/app/application_runtime_coordinator.dart').readAsStringSync(),
    ].join('\n');

    expect(sources.contains('Timer.periodic'), isFalse);
    expect(sources.contains('_retryWelcomeProjectionIfNeeded'), isFalse);
    expect(sources.contains('verifyContact(contact.id)'), isFalse);
    expect(sources.contains('openOrStartConversation(contact)'), isFalse);
  });
}
