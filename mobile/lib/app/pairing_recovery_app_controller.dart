import 'dart:async';

import '../client_runtime.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_legacy.dart' as legacy;
import 'sequential_app_controller.dart';

class PairingRecoveryAppController extends SequentialAppController {
  static const _pollInterval = Duration(seconds: 2);
  static const _pairingNoticePrefix = 'Oczekujące zaproszenia:';

  Timer? _pairingPoll;
  Future<void>? _pairingPollInFlight;
  DateTime? _lastPairingSync;

  @override
  legacy.AppState build() {
    final initial = super.build();
    _pairingPoll = Timer.periodic(_pollInterval, (_) => _pollPairing());
    ref.onDispose(() => _pairingPoll?.cancel());
    return initial;
  }

  @override
  Future<void> initialize() async {
    _lastPairingSync = null;
    await super.initialize();
    if (!state.transport.connected) return;
    try {
      await refreshData(forcePairing: true, allowAutoTorka: false);
    } catch (_) {
      // Startup remains usable; periodic reconciliation retries pairing sync.
    }
  }

  @override
  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) async {
    final lastSync = _lastPairingSync;
    final pairingDue =
        lastSync == null || DateTime.now().difference(lastSync) >= _pollInterval;
    final effectiveForcePairing =
        forcePairing || pairingDue || _isPairingAction(state.action);

    await super.refreshData(
      forcePairing: effectiveForcePairing,
      allowAutoTorka: allowAutoTorka,
    );
    if (effectiveForcePairing) {
      _lastPairingSync = DateTime.now();
    }
    _updatePairingNotice();
  }

  @override
  Future<void> updateVisibility(bool foreground) async {
    await super.updateVisibility(foreground);
    if (!foreground) return;
    try {
      await refreshData(forcePairing: true, allowAutoTorka: false);
    } catch (_) {
      // Foreground reconciliation is best-effort; the periodic poll retries it.
    }
  }

  bool _isPairingAction(String action) => switch (action) {
    OperationAction.refreshPairing ||
    OperationAction.submitPairing ||
    OperationAction.acceptPairing ||
    OperationAction.rejectPairing ||
    OperationAction.archivePairing ||
    OperationAction.cancelPairing => true,
    _ => false,
  };

  void _pollPairing() {
    if (!state.transport.connected ||
        state.isLoading ||
        _pairingPollInFlight != null ||
        _isPairingAction(state.action)) {
      return;
    }

    late final Future<void> run;
    run = refreshData(allowAutoTorka: false).whenComplete(() {
      if (identical(_pairingPollInFlight, run)) {
        _pairingPollInFlight = null;
      }
    });
    _pairingPollInFlight = run;
    unawaited(
      run.catchError((Object error, StackTrace stackTrace) {
        // Polling is recovery-only. Explicit user actions still surface errors.
      }),
    );
  }

  void _updatePairingNotice() {
    final pending = state.inbox
        .where((item) => item.status == InviteState.pending)
        .length;
    final current = state.notice;
    if (pending > 0) {
      final suffix = pending == 1
          ? '1 nowe zaproszenie.'
          : '$pending nowe zaproszenia.';
      final notice = '$_pairingNoticePrefix $suffix';
      if (current != notice &&
          (current.isEmpty || current.startsWith(_pairingNoticePrefix))) {
        state = state.copyWith(notice: notice);
      }
    } else if (current.startsWith(_pairingNoticePrefix)) {
      state = state.copyWith(notice: '');
    }
  }
}
