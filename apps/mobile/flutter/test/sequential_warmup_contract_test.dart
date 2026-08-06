import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('warmup opens on local data before the P2P endpoint is ready', () {
    final coordinator = File(
      'lib/app/application_runtime_coordinator.dart',
    ).readAsStringSync();
    final orchestrator = File(
      'lib/core/startup/sequential_startup_orchestrator.dart',
    ).readAsStringSync();

    const phases = [
      'SequentialStartupPhase.engine',
      'SequentialStartupPhase.localData',
    ];

    var previous = -1;
    for (final phase in phases) {
      final current = coordinator.indexOf(phase, previous + 1);
      expect(current, greaterThan(previous), reason: '$phase must be ordered');
      previous = current;
    }

    expect(orchestrator, contains('localData,'));
    expect(coordinator, isNot(contains('waitForRelay')));
    expect(coordinator, isNot(contains('observeRelayReady')));
  });

  test(
    'startup consumes canonical repository events with cache side effects',
    () {
      final coordinator = File(
        'lib/app/application_runtime_coordinator.dart',
      ).readAsStringSync();

      expect(coordinator, contains('_events ??= _repository.events.listen('));
      expect(
        coordinator,
        isNot(contains('_events ??= _runtime.events.listen(')),
      );
      expect(
        coordinator,
        contains('onError: (Object error, StackTrace stackTrace)'),
      );
      expect(
        coordinator,
        contains('Desktop runtime event stream closed during warmup'),
      );
      expect(coordinator, contains('await _runtime.connect().timeout'));
    },
  );

  test(
    'startup refreshes are serialized and event refreshes are conflated',
    () {
      final coordinator = File(
        'lib/app/application_runtime_coordinator.dart',
      ).readAsStringSync();

      expect(coordinator, contains('Future<void> _refreshTail'));
      expect(coordinator, contains('_refreshTail = _refreshTail.catchError'));
      expect(coordinator, contains('bool _eventRefreshQueued'));
      expect(coordinator, contains('while (_eventRefreshQueued && !_warming)'));
      expect(coordinator, contains('if (_warming)'));
      expect(coordinator, contains('_refreshAfterWarmup = true'));
      expect(coordinator, contains('final messageRefreshes = Set<String>.of('));
      expect(coordinator, contains('await _repository.messages('));
    },
  );

  test('contact endpoint cannot be mistaken for the local onion endpoint', () {
    final coordinator = File(
      'lib/app/application_runtime_coordinator.dart',
    ).readAsStringSync();

    expect(
      coordinator,
      contains('final local = identity.isNotEmpty && contactId == identity;'),
    );
    expect(
      coordinator,
      isNot(contains('(identity.isEmpty || contactId == identity)')),
    );
  });

  test('desktop runtime still fences process and bootstrap generations', () {
    final source = File(
      '../../desktop/flutter/lib/platform/desktop/windows_runtime.dart',
    ).readAsStringSync();

    expect(source, contains('Future<void>? _startInFlight'));
    expect(source, contains('Future<void>? _bootstrapInFlight'));
    expect(source, contains('int _processGeneration = 0'));
    expect(source, contains('await bootstrap.timeout'));
    expect(source, contains('_owns(process, generation)'));
  });
}
