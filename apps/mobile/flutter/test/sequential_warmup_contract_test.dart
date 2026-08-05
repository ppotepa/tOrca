import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active provider layers pairing recovery over sequential warmup', () {
    final wrapper = File('lib/app/app_controller.dart').readAsStringSync();
    final recovery = File(
      'lib/app/pairing_recovery_app_controller.dart',
    ).readAsStringSync();
    final notifications = File(
      'lib/app/notification_safe_app_controller.dart',
    ).readAsStringSync();

    expect(
      wrapper,
      contains("import 'notification_safe_app_controller.dart';"),
    );
    expect(wrapper, contains('() {'));
    expect(wrapper, contains('return NotificationSafeAppController();'));
    expect(notifications, contains('extends PairingRecoveryAppController'));
    expect(recovery, contains('extends SequentialAppController'));
    expect(wrapper, contains("export 'app_controller_base.dart';"));
  });

  test('warmup opens on local data without a global relay gate', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();
    const phases = [
      'SequentialStartupPhase.engine',
      'SequentialStartupPhase.localData',
    ];

    var previous = -1;
    for (final phase in phases) {
      final current = source.indexOf(phase, previous + 1);
      expect(current, greaterThan(previous), reason: '$phase must be ordered');
      previous = current;
    }

    expect(source, isNot(contains('waitForRelay')));
    expect(source, isNot(contains('observeRelayReady')));
    expect(source, contains('Local data is the shell gate'));
  });

  test(
    'startup consumes canonical repository events with cache side effects',
    () {
      final source = File(
        'lib/app/sequential_app_controller.dart',
      ).readAsStringSync();

      expect(source, contains('_events ??= _repository.events.listen('));
      expect(source, isNot(contains('_events ??= _runtime.events.listen(')));
      expect(
        source,
        contains('onError: (Object error, StackTrace stackTrace)'),
      );
      expect(
        source,
        contains('Desktop runtime event stream closed during warmup'),
      );
      expect(source, contains('await _runtime.connect().timeout'));
    },
  );

  test(
    'startup refreshes are serialized and event refreshes are conflated',
    () {
      final source = File(
        'lib/app/sequential_app_controller.dart',
      ).readAsStringSync();

      expect(source, contains('Future<void> _refreshTail'));
      expect(source, contains('_refreshTail = _refreshTail.catchError'));
      expect(source, contains('bool _eventRefreshQueued'));
      expect(source, contains('while (_eventRefreshQueued && !_warming)'));
      expect(source, contains('if (_warming)'));
      expect(source, contains('_refreshAfterWarmup = true'));
      expect(source, contains('await super.refreshData('));
      expect(source, contains('final messageRefreshes = Set<String>.of('));
      expect(source, contains('await _repository.messages('));
    },
  );

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
