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
