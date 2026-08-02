import 'dart:async';

import '../client_runtime.dart';
import '../core/models/domain.dart';
import '../core/problems/runtime_problem_classifier.dart';
import '../shared/async/async_operation_state.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_base.dart' as base;
import 'sequential_app_controller.dart';
import 'ui_operation_registry.dart';

class PairingRecoveryAppController extends SequentialAppController {
  static const _watchdogInterval = Duration(seconds: 20);
  static const _minimumSyncInterval = Duration(seconds: 3);
  static const _pairingNoticePrefix = 'Oczekujące zaproszenia:';

  Timer? _pairingWatchdog;
  Future<void>? _pairingSyncInFlight;
  Future<void>? _autoTrustInFlight;
  bool _pairingSyncQueued = false;
  bool _sanitizingProblem = false;
  DateTime? _lastPairingSync;
  String? _lastAutoOpenedContactId;

  @override
  base.AppState build() {
    final initial = super.build();
    listenSelf((_, next) => _sanitizeTechnicalProblem(next.error));
    _pairingWatchdog = Timer.periodic(
      _watchdogInterval,
      (_) => _schedulePairingSync(force: false),
    );
    ref.onDispose(() => _pairingWatchdog?.cancel());
    return initial;
  }

  @override
  Future<void> initialize() async {
    _lastPairingSync = null;
    _begin(UiOperationKey.contactsLoad, 'Ładowanie kontaktów');
    _begin(UiOperationKey.conversationsLoad, 'Ładowanie rozmów');
    await super.initialize();
    _finishFromController(UiOperationKey.contactsLoad, 'Ładowanie kontaktów');
    _finishFromController(UiOperationKey.conversationsLoad, 'Ładowanie rozmów');
    if (state.transport.connected) {
      await _synchronizePairing(force: true);
    }
  }

  @override
  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) async {
    final effectiveForcePairing =
        forcePairing || _isPairingAction(state.action);

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
  Future<void> submitPairingCode(String code) => _runPairingMutation(
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
  Future<void> acceptPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingAccept(id),
    'Akceptowanie zaproszenia',
    () => super.acceptPairing(id),
    targetId: id,
  );

  @override
  Future<void> rejectPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingReject(id),
    'Odrzucanie zaproszenia',
    () => super.rejectPairing(id),
    targetId: id,
  );

  @override
  Future<void> cancelPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingCancel(id),
    'Anulowanie zaproszenia',
    () => super.cancelPairing(id),
    targetId: id,
  );

  @override
  Future<void> archiveInvite(String id) => _runPairingMutation(
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
    if (foreground) await _synchronizePairing(force: true);
  }

  /// Called only after a newly discovered pairing contact has been promoted
  /// to verified state. Subclasses may persist a fresh relationship boundary
  /// before the conversation is opened.
  Future<void> onPairingContactActivated(ContactRecord contact) async {}

  Future<void> _runPairingMutation(
    String key,
    String label,
    Future<void> Function() operation, {
    String? targetId,
  }) async {
    await _runVoid(key, label, operation, targetId: targetId);
    await _synchronizePairing(force: true);
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
    try {
      await operation();
    } finally {
      _finishFromController(key, label, targetId);
    }
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
    final classification = classifyRuntimeProblem(error);
    final visibleError = classification.userVisible ? error : '';
    try {
      ref.read(uiOperationProvider(key).notifier).state = AsyncOperationState(
        phase: visibleError.isEmpty
            ? AsyncOperationPhase.succeeded
            : AsyncOperationPhase.failed,
        label: label,
        targetId: targetId,
        error: visibleError,
      );
    } on StateError {
      // An async runtime operation may finish after its ProviderContainer was
      // disposed (for example during host shutdown). Its result is no longer
      // observable and must not turn a clean shutdown into an uncaught error.
    }
  }

  void _sanitizeTechnicalProblem(String message) {
    if (_sanitizingProblem || message.trim().isEmpty) return;
    final classification = classifyRuntimeProblem(message);
    if (classification.userVisible) return;
    _sanitizingProblem = true;
    state = state.copyWith(error: '');
    _sanitizingProblem = false;
  }

  void _schedulePairingSync({required bool force}) {
    if (!state.transport.connected || state.isLoading) return;
    _pairingSyncQueued = true;
    if (_pairingSyncInFlight != null) return;

    late final Future<void> run;
    run = _drainPairingSync(force: force).whenComplete(() {
      if (identical(_pairingSyncInFlight, run)) _pairingSyncInFlight = null;
      if (_pairingSyncQueued) _schedulePairingSync(force: false);
    });
    _pairingSyncInFlight = run;
    unawaited(run.catchError((Object _, StackTrace _) {}));
  }

  Future<void> _drainPairingSync({required bool force}) async {
    var forceNext = force;
    while (_pairingSyncQueued) {
      _pairingSyncQueued = false;
      await _synchronizePairing(force: forceNext);
      forceNext = false;
    }
  }

  Future<void> _synchronizePairing({required bool force}) async {
    if (!state.transport.connected) return;
    final last = _lastPairingSync;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _minimumSyncInterval) {
      return;
    }
    final knownContactIds = state.contacts.map((contact) => contact.id).toSet();
    try {
      await refreshData(forcePairing: true, allowAutoTorka: false);
      _lastPairingSync = DateTime.now();
      final newContact = state.contacts.cast<ContactRecord?>().firstWhere(
        (contact) => contact != null && !knownContactIds.contains(contact.id),
        orElse: () => null,
      );
      await _promoteTrustedPairingContacts(openContactId: newContact?.id);
    } catch (_) {
      // Connection recovery and the watchdog will retry. A transport outage is
      // not a global user-facing pairing error.
    }
  }

  Future<void> _promoteTrustedPairingContacts({String? openContactId}) {
    final current = _autoTrustInFlight;
    if (current != null) return current;

    late final Future<void> run;
    run = _runTrustedContactPromotion(openContactId).whenComplete(() {
      if (identical(_autoTrustInFlight, run)) _autoTrustInFlight = null;
    });
    _autoTrustInFlight = run;
    return run;
  }

  Future<void> _runTrustedContactPromotion(String? openContactId) async {
    var changed = false;
    for (final contact in state.contacts.where(
      (contact) => !contact.verified,
    )) {
      try {
        await super.verifyContact(contact.id);
        changed = true;
      } catch (_) {
        // The next pairing reconciliation retries an interrupted local promote.
      }
    }
    if (changed) {
      await super.refreshData(forcePairing: false, allowAutoTorka: false);
    }

    if (openContactId == null ||
        openContactId.isEmpty ||
        _lastAutoOpenedContactId == openContactId) {
      return;
    }
    ContactRecord? contact;
    for (final candidate in state.contacts) {
      if (candidate.id == openContactId) {
        contact = candidate;
        break;
      }
    }
    if (contact == null || !contact.verified) return;

    await onPairingContactActivated(contact);
    _lastAutoOpenedContactId = openContactId;
    await super.openOrStartConversation(contact);
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
