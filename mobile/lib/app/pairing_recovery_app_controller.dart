import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../client_runtime.dart';
import '../core/models/domain.dart';
import '../shared/async/async_operation_state.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_legacy.dart' as legacy;
import 'sequential_app_controller.dart';
import 'ui_operation_registry.dart';

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
    _begin(UiOperationKey.contactsLoad, 'Ładowanie kontaktów');
    _begin(UiOperationKey.conversationsLoad, 'Ładowanie rozmów');
    await super.initialize();
    _finishFromController(UiOperationKey.contactsLoad, 'Ładowanie kontaktów');
    _finishFromController(
      UiOperationKey.conversationsLoad,
      'Ładowanie rozmów',
    );
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
    final repository = ref.read(legacy.runtimeRepositoryProvider);
    final lastSync = _lastPairingSync;
    final pairingDue =
        lastSync == null || DateTime.now().difference(lastSync) >= _pollInterval;
    final effectiveForcePairing =
        forcePairing ||
        pairingDue ||
        repository.applicationState.isStale ||
        _isPairingAction(state.action);

    await super.refreshData(
      forcePairing: effectiveForcePairing,
      allowAutoTorka: allowAutoTorka,
    );
    if (effectiveForcePairing) _lastPairingSync = DateTime.now();
    _updatePairingNotice();
  }

  @override
  Future<void> retryTor() => _runVoid(
    UiOperationKey.connectionRetry,
    'Ponawianie połączenia',
    super.retryTor,
  );

  @override
  Future<void> setNickname(String nickname) => _runVoid(
    UiOperationKey.nicknameSave,
    'Zapisywanie nicku',
    () => super.setNickname(nickname),
  );

  @override
  Future<void> openConversation(String id) => _runVoid(
    UiOperationKey.conversationOpen(id),
    'Otwieranie rozmowy',
    () async {
      _begin(UiOperationKey.messagesLoad(id), 'Ładowanie wiadomości', id);
      await super.openConversation(id);
      _finishFromController(
        UiOperationKey.messagesLoad(id),
        'Ładowanie wiadomości',
        id,
      );
    },
    targetId: id,
  );

  @override
  Future<void> openOrStartConversation(ContactRecord contact) => _runVoid(
    UiOperationKey.conversationStart(contact.id),
    'Uruchamianie rozmowy',
    () => super.openOrStartConversation(contact),
    targetId: contact.id,
  );

  @override
  Future<void> sendMessage(String text, {String? replyToMessageId}) {
    final id = state.selectedConversationId ?? '';
    return _runVoid(
      UiOperationKey.messageSend(id),
      'Wysyłanie wiadomości',
      () => super.sendMessage(text, replyToMessageId: replyToMessageId),
      targetId: id,
    );
  }

  @override
  Future<void> retryMessage(String messageId) => _runVoid(
    UiOperationKey.messageRetry(messageId),
    'Ponawianie wiadomości',
    () => super.retryMessage(messageId),
    targetId: messageId,
  );

  @override
  Future<void> deleteMessageLocal(String messageId) => _runVoid(
    UiOperationKey.messageDelete(messageId),
    'Usuwanie wiadomości',
    () => super.deleteMessageLocal(messageId),
    targetId: messageId,
  );

  @override
  Future<void> submitPairingCode(String code) => _runVoid(
    UiOperationKey.pairingSubmit,
    'Przetwarzanie kodu parowania',
    () => super.submitPairingCode(code),
  );

  @override
  Future<InviteCode?> refreshInviteCode() async {
    const key = UiOperationKey.inviteCodeLoad;
    _begin(key, 'Pobieranie kodu parowania');
    final value = await super.refreshInviteCode();
    _finishFromController(key, 'Pobieranie kodu parowania');
    return value;
  }

  @override
  Future<void> acceptPairing(String id) => _runVoid(
    UiOperationKey.pairingAccept(id),
    'Akceptowanie zaproszenia',
    () => super.acceptPairing(id),
    targetId: id,
  );

  @override
  Future<void> rejectPairing(String id) => _runVoid(
    UiOperationKey.pairingReject(id),
    'Odrzucanie zaproszenia',
    () => super.rejectPairing(id),
    targetId: id,
  );

  @override
  Future<void> cancelPairing(String id) => _runVoid(
    UiOperationKey.pairingCancel(id),
    'Anulowanie zaproszenia',
    () => super.cancelPairing(id),
    targetId: id,
  );

  @override
  Future<void> archiveInvite(String id) => _runVoid(
    UiOperationKey.pairingArchive(id),
    'Archiwizowanie zaproszenia',
    () => super.archiveInvite(id),
    targetId: id,
  );

  @override
  Future<void> verifyContact(String id) => _runVoid(
    UiOperationKey.contactVerify(id),
    'Weryfikowanie kontaktu',
    () => super.verifyContact(id),
    targetId: id,
  );

  @override
  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) => _runVoid(
    UiOperationKey.contactSettingsFor(contact.id),
    'Zapisywanie ustawień kontaktu',
    () => super.updateContactSettings(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    ),
    targetId: contact.id,
  );

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

  Future<void> _runVoid(
    String key,
    String label,
    Future<void> Function() operation, {
    String? targetId,
  }) async {
    _begin(key, label, targetId);
    await operation();
    _finishFromController(key, label, targetId);
  }

  void _begin(String key, String label, [String? targetId]) {
    ref.read(uiOperationProvider(key).notifier).state = AsyncOperationState(
      phase: AsyncOperationPhase.running,
      label: label,
      targetId: targetId,
    );
  }

  void _finishFromController(String key, String label, [String? targetId]) {
    final error = state.error.trim();
    ref.read(uiOperationProvider(key).notifier).state = AsyncOperationState(
      phase: error.isEmpty
          ? AsyncOperationPhase.succeeded
          : AsyncOperationPhase.failed,
      label: label,
      targetId: targetId,
      error: error,
    );
  }

  void _pollPairing() {
    if (!state.transport.connected ||
        state.isLoading ||
        _pairingPollInFlight != null ||
        _isPairingAction(state.action)) {
      return;
    }

    late final Future<void> run;
    run = refreshData(allowAutoTorka: false).whenComplete(() {
      if (identical(_pairingPollInFlight, run)) _pairingPollInFlight = null;
    });
    _pairingPollInFlight = run;
    unawaited(run.catchError((Object _, StackTrace __) {}));
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
