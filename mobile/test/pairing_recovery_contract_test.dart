import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active provider enables the pairing recovery controller', () {
    final wrapper = File('lib/app/app_controller.dart').readAsStringSync();

    expect(
      wrapper,
      contains("import 'pairing_recovery_app_controller.dart';"),
    );
    expect(wrapper, contains('() => PairingRecoveryAppController()'));
  });

  test('pairing reconciliation is periodic and forced after user actions', () {
    final source = File(
      'lib/app/pairing_recovery_app_controller.dart',
    ).readAsStringSync();

    expect(source, contains('Duration(seconds: 2)'));
    expect(source, contains('effectiveForcePairing'));
    expect(source, contains('forcePairing: true'));
    expect(source, contains('OperationAction.acceptPairing'));
    expect(source, contains('OperationAction.rejectPairing'));
    expect(source, contains('OperationAction.cancelPairing'));
    expect(source, contains('updateVisibility(bool foreground)'));
  });

  test('pairing actions expose persistent per-button busy feedback', () {
    final source = File(
      'lib/shared/widgets/action_status_strip.dart',
    ).readAsStringSync();

    expect(source, contains('ref.watch(appControllerProvider)'));
    expect(source, contains('_IncomingPairingPanel'));
    expect(source, contains('_OutgoingPairingPanel'));
    expect(source, contains('RetroActivityIndicator'));
    expect(source, contains("'Akceptowanie…'"));
    expect(source, contains("'Odrzucanie…'"));
    expect(source, contains("'Anulowanie…'"));
    expect(source, contains('_acceptAndWaitForContact'));
    expect(source, contains('forcePairing: true'));
  });

  test('sequential runtime events invalidate pairing cache explicitly', () {
    final source = File(
      'lib/app/sequential_app_controller.dart',
    ).readAsStringSync();

    expect(source, contains('EngineContract.inviteReceived'));
    expect(source, contains('EngineContract.inviteStateChanged'));
    expect(source, contains('_repository.invalidatePairingCache()'));
  });

  test('pairing dialog never auto-rejects a valid pending request', () {
    final dialog = File(
      'lib/features/onboarding/onboarding_views.dart',
    ).readAsStringSync();

    expect(dialog, contains('Zaproszenie oczekuje na Twoją decyzję'));
    expect(dialog, contains('RetroActivityIndicator'));
    expect(dialog, isNot(contains('_approvalRemaining')));
    expect(dialog, isNot(contains('_reject(expired: true)')));
  });
}
