import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing state is sourced only from the application snapshot', () {
    const forbiddenSymbols = <String>[
      'invalidatePairingCache',
      'pairingInboxItems',
      'pairingOutboxItems',
      'setPairing(',
      '_latestPairingSnapshot',
      '_pairingCache',
    ];

    final violations = <String>[];
    final libDirectory = Directory('lib');

    expect(
      libDirectory.existsSync(),
      isTrue,
      reason: 'Run this test from apps/mobile/flutter.',
    );

    for (final entity in libDirectory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }

      final source = entity.readAsStringSync();
      for (final symbol in forbiddenSymbols) {
        if (source.contains(symbol)) {
          violations.add('${entity.path}: $symbol');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Pairing must remain part of the atomic ApplicationSnapshot '
          'projection. Do not reintroduce a pairing-specific cache, controller '
          'copy, setter, or invalidation path. Violations:\n'
          '${violations.join('\n')}',
    );
  });
}
