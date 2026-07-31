import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active app controller provider uses the sequential implementation', () {
    final wrapper = File('lib/app/app_controller.dart').readAsStringSync();

    expect(wrapper, contains("import 'sequential_app_controller.dart';"));
    expect(wrapper, contains('() => SequentialAppController()'));
    expect(
      wrapper,
      contains("export 'app_controller_legacy.dart' hide appControllerProvider"),
    );
  });

  test('warmup phases are awaited in canonical order', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();
    const phases = [
      'SequentialStartupPhase.engine',
      'SequentialStartupPhase.localData',
      'SequentialStartupPhase.tor',
      'SequentialStartupPhase.relay',
      'SequentialStartupPhase.peerListener',
      'SequentialStartupPhase.onionService',
      'SequentialStartupPhase.communication',
      'SequentialStartupPhase.complete',
    ];

    var previous = -1;
    for (final phase in phases) {
      final current = source.indexOf(phase, previous + 1);
      expect(current, greaterThan(previous), reason: '$phase must be ordered');
      previous = current;
    }

    expect(source, contains('await _startup.waitForTor(generation)'));
    expect(source, contains('await _startup.waitForRelay(generation)'));
    expect(source, contains('await _startup.waitForPeerListener(generation)'));
    expect(source, contains('await _waitForOnionService(generation)'));
  });

  test('startup owns the runtime event stream without repository side effects', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();

    expect(source, contains('_events ??= _runtime.events.listen('));
    expect(source, isNot(contains('_repository.events.listen(')));
    expect(source, contains('onError: (Object error, StackTrace stackTrace)'));
    expect(source, contains('Desktop runtime event stream closed during warmup'));
    expect(source, contains('await _runtime.connect().timeout'));
  });

  test('startup refreshes are serialized and event refreshes are conflated', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();

    expect(source, contains('Future<void> _refreshTail'));
    expect(source, contains('_refreshTail = _refreshTail.catchError'));
    expect(source, contains('bool _eventRefreshQueued'));
    expect(source, contains('while (_eventRefreshQueued && !_warming)'));
    expect(source, contains('if (_warming)'));
    expect(source, contains('_refreshAfterWarmup = true'));
    expect(source, contains('await _repository.applicationSnapshot(force: true)'));
  });

  test('contact endpoint cannot be mistaken for the local onion endpoint', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('final local = identity.isNotEmpty && contactId == identity;'),
    );
    expect(
      source,
      isNot(contains('(identity.isEmpty || contactId == identity)')),
    );
  });

  test('desktop runtime still fences process and bootstrap generations', () {
    final source = File('lib/windows_runtime.dart').readAsStringSync();

    expect(source, contains('Future<void>? _startInFlight'));
    expect(source, contains('Future<void>? _bootstrapInFlight'));
    expect(source, contains('int _processGeneration = 0'));
    expect(source, contains('await bootstrap.timeout'));
    expect(source, contains('_owns(process, generation)'));
  });
}
