import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../client_runtime.dart';
import '../core/application_state/application_snapshot.dart';
import '../core/application_state/application_state_store.dart';
import '../core/runtime/runtime_repository.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
);

const _devTorkaPairingCode = String.fromEnvironment(
  'TORCHAT_TORKA_PAIRING_CODE',
  defaultValue: '',
);

@visibleForTesting
String? debugTorkaPairingCodeOverride;

@visibleForTesting
Duration? debugTorkaWatchdogIntervalOverride;

@visibleForTesting
int? debugTorkaWatchdogMaxAttemptsOverride;

enum ControllerScreen { boot, nickname, main }

enum MainDestination { chats, contacts, account, settings, tor }

class AppState {
  const AppState({
    this.screen = ControllerScreen.boot,
    this.destination = MainDestination.chats,
    this.ownInvite,
    this.transport = const RuntimeTorStatus(),
    this.peerServerStatus = PeerServerStatus.starting,
    this.transportStatuses = const {},
    this.startupSteps = const [],
    this.selectedConversationId,
    this.isLoading = false,
    this.action = '',
    this.error = '',
    this.notice = '',
    this.typingContacts = const {},
    this.onlineContacts = const {},
    this.applicationSnapshot,
    this.pairingInboxItems = const [],
    this.pairingOutboxItems = const [],
  });
  final ControllerScreen screen;
  final MainDestination destination;
  final ApplicationSnapshot? applicationSnapshot;
  final List<PairingItem> pairingInboxItems;
  final List<PairingItem> pairingOutboxItems;
  RuntimeIdentity get identity =>
      applicationSnapshot?.identity ?? const RuntimeIdentity();
  RuntimeProfile get profile =>
      applicationSnapshot?.profile ?? const RuntimeProfile();
  List<ContactRecord> get contacts => applicationSnapshot?.contacts ?? const [];
  List<ConversationSummary> get conversations =>
      applicationSnapshot?.conversations ?? const [];
  // Keep the store fallback for callers that construct a transient AppState
  // directly (for example notifications/tests). Controller-owned state is
  // still the normal source after RuntimeRepository.refresh().
  List<PairingItem> get inbox => pairingInboxItems.isNotEmpty
      ? pairingInboxItems
      : ApplicationStateStore.shared.pairingInbox;
  List<PairingItem> get outbox => pairingOutboxItems.isNotEmpty
      ? pairingOutboxItems
      : ApplicationStateStore.shared.pairingOutbox;
  List<ChatMessage> get messages =>
      ApplicationStateStore.shared.messages(selectedConversationId ?? '');
  final InviteCode? ownInvite;
  final RuntimeTorStatus transport;
  final PeerServerStatus peerServerStatus;
  final Map<TransportComponent, TransportStatusSnapshot> transportStatuses;
  final List<StartupStep> startupSteps;
  final String? selectedConversationId;
  final bool isLoading;
  final String action;
  final String error;
  final String notice;
  final Map<String, bool> typingContacts;
  final Map<String, bool> onlineContacts;

  int get activeInviteCount => inbox.pendingCount;

  List<ContactRequest> pairingRequests() =>
      inbox.map((invite) => invite.asContactRequest()).toList();

  ConversationSummary? selectedConversation(
    List<ConversationSummary> conversations,
  ) {
    final id = selectedConversationId;
    if (id == null) return null;
    return conversations.firstOrNullWhere((item) => item.id == id);
  }

  ContactRecord? selectedContact(
    List<ContactRecord> contacts,
    List<ConversationSummary> conversations,
  ) {
    final conversation = selectedConversation(conversations);
    if (conversation == null) {
      return selectedConversationId == null
          ? null
          : contacts.firstOrNullWhere(
              (item) => item.id == selectedConversationId,
            );
    }
    return contacts.firstOrNullWhere(
      (item) => item.id == conversation.contactId,
    );
  }

  AppState copyWith({
    ControllerScreen? screen,
    MainDestination? destination,
    InviteCode? ownInvite,
    RuntimeTorStatus? transport,
    PeerServerStatus? peerServerStatus,
    Map<TransportComponent, TransportStatusSnapshot>? transportStatuses,
    List<StartupStep>? startupSteps,
    String? selectedConversationId,
    bool clearSelection = false,
    bool? isLoading,
    String? action,
    String? error,
    String? notice,
    Map<String, bool>? typingContacts,
    Map<String, bool>? onlineContacts,
    ApplicationSnapshot? applicationSnapshot,
    List<PairingItem>? pairingInboxItems,
    List<PairingItem>? pairingOutboxItems,
  }) => AppState(
    screen: screen ?? this.screen,
    destination: destination ?? this.destination,
    ownInvite: ownInvite ?? this.ownInvite,
    transport: transport ?? this.transport,
    peerServerStatus: peerServerStatus ?? this.peerServerStatus,
    transportStatuses: transportStatuses ?? this.transportStatuses,
    startupSteps: startupSteps ?? this.startupSteps,
    selectedConversationId: clearSelection
        ? null
        : selectedConversationId ?? this.selectedConversationId,
    isLoading: isLoading ?? this.isLoading,
    action: action ?? this.action,
    error: error ?? this.error,
    notice: notice ?? this.notice,
    typingContacts: typingContacts ?? this.typingContacts,
    onlineContacts: onlineContacts ?? this.onlineContacts,
    applicationSnapshot: applicationSnapshot ?? this.applicationSnapshot,
    pairingInboxItems: pairingInboxItems ?? this.pairingInboxItems,
    pairingOutboxItems: pairingOutboxItems ?? this.pairingOutboxItems,
  );
}

abstract class AppController extends Notifier<AppState> {
  late final RuntimeRepository _repository;
  bool _torkaPairingInFlight = false;
  bool _torkaConversationInFlight = false;
  String? _torkaInstallationIdHint;
  Timer? _torkaWatchdog;
  int _torkaWatchdogAttempts = 0;

  @override
  AppState build() {
    _repository = ref.watch(runtimeRepositoryProvider);
    ref.onDispose(() {
      _torkaWatchdog?.cancel();
    });
    return const AppState();
  }

  Future<void> initialize();

  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) async {
    late final bool peerEndpointAvailable;

    final snapshot = await _repository.refresh(
      includePairing: forcePairing,
      bypassCooldown: true,
    );
    final applicationSnapshot = snapshot.application;
    // Use the pairing snapshot captured by this refresh, not the mutable
    // repository cache, which may already have been invalidated by a newer
    // invite event.
    final pairing = snapshot.pairing;
    peerEndpointAvailable = snapshot.local.peerEndpointAvailable;
    final peerServerStatus = _peerServerStatusForRefresh(
      state.transport,
      peerEndpointAvailable,
      current: state.peerServerStatus,
    );
    state = state.copyWith(
      applicationSnapshot: applicationSnapshot,
      pairingInboxItems: pairing?.inbox ?? state.pairingInboxItems,
      pairingOutboxItems: pairing?.outbox ?? state.pairingOutboxItems,
      peerServerStatus: peerServerStatus,
      startupSteps: _startupStepsForEndpoint(
        state.startupSteps,
        peerEndpointAvailable,
        torReady: state.transport.usable,
        relayReady: state.transport.connected,
        peerServerStatus: peerServerStatus,
      ),
    );
    if (state.transport.connected) {
      state = state.copyWith(
        screen: _screenAfterConnect(
          state.profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: peerServerStatus,
        ),
      );
      if (allowAutoTorka) {
        unawaited(_maybeAutoPairTorka());
      }
    }
  }

  Future<void> retryTor() async {
    state = state.copyWith(
      error: '',
      notice: 'Ponawianie połączenia transportowego…',
    );
    try {
      await _repository.connect();
      await _repository.refresh(includePairing: true, bypassCooldown: true);
    } catch (error) {
      state = state.copyWith(error: _message(error), notice: '');
    }
  }

  Future<void> setNickname(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: state.peerServerStatus,
        ),
        error: '',
      );
      unawaited(_maybeAutoPairTorka());
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  void selectDestination(MainDestination destination) {
    if (destination != MainDestination.chats) {
      unawaited(_repository.closeConversation());
    }
    state = state.copyWith(
      destination: destination,
      clearSelection: true,
      error: '',
    );
  }

  Future<void> openConversation(String id) async {
    try {
      final conversation = state.conversations.firstOrNullWhere(
        (item) => item.id == id || item.contactId == id,
      );
      final activated = await _repository.activateConversation(
        conversation?.contactId ?? id,
      );
      state = state.copyWith(
        selectedConversationId: activated.conversation.id,
        destination: MainDestination.chats,
        error: '',
      );
      // Read receipts deliberately remain unavailable in 0.1: the current
      // MLS transport advances the ratchet, so a lossy ephemeral receipt could
      // desynchronize the next durable message. Do not invoke a command that
      // the engine intentionally reports as unsupported.
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> openOrStartConversation(ContactRecord contact) async {
    state = state.copyWith(
      destination: MainDestination.chats,
      action: OperationAction.startConversation,
      error: '',
      notice: 'Oczekiwanie na handshake MLS…',
    );
    try {
      final activated = await _repository.activateConversation(contact.id);
      state = state.copyWith(
        selectedConversationId: activated.conversation.id,
        action: '',
        notice: '',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  void closeConversation() {
    unawaited(_repository.closeConversation());
    state = state.copyWith(clearSelection: true);
  }

  Future<void> sendMessage(String text, {String? replyToMessageId}) async {
    final id = state.selectedConversationId;
    if (id == null || text.trim().isEmpty) return;
    state = state.copyWith(action: OperationAction.sendMessage, error: '');
    try {
      await _repository.sendMessage(
        id,
        text.trim(),
        replyToMessageId: replyToMessageId,
      );
      // The runtime invalidates its snapshot asynchronously after accepting
      // an outbound message.  Refresh the selected conversation immediately
      // so the canonical queued message is visible without waiting for a
      // later transport event.
      await _repository.messages(id, force: true);
      await _repository.refreshDataForConversation(id);
      state = state.copyWith(action: '', notice: '');
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  Future<void> retryMessage(String messageId) async {
    try {
      await _repository.retryMessage(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
        state = state.copyWith(error: '');
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> deleteMessageLocal(String messageId) async {
    try {
      await _repository.deleteMessageLocal(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
        state = state.copyWith(error: '');
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> setTyping(bool typing) async {
    // Disabled until ephemeral MLS signals have durable, ratchet-safe
    // delivery. Do not submit a command which the engine explicitly rejects.
    return;
  }

  Future<void> updateVisibility(bool foreground) async {
    await _repository.updateAppVisibility(foreground);
    // Presence currently uses the same disabled ephemeral channel as typing.
    // Platform visibility still drives lifecycle and background execution.
  }

  Future<void> submitPairingCode(String code) async {
    if (!state.transport.connected) {
      state = state.copyWith(
        error: 'Poczekaj na zielony pasek połączenia Tor.',
        notice: '',
      );
      return;
    }
    if (state.profile.nickname.trim().length < 2) {
      state = state.copyWith(
        error: 'Najpierw ustaw nazwę użytkownika na tym urządzeniu.',
        notice: '',
      );
      return;
    }
    final normalizedCode = pairingCodeDigits(code);
    if (normalizedCode == null) {
      state = state.copyWith(error: 'Kod musi zawierać dokładnie 8 cyfr.');
      return;
    }
    state = state.copyWith(
      action: OperationAction.submitPairing,
      error: '',
      notice: '',
    );
    try {
      await _cancelBlockingTorkaOutboxIfNeeded(normalizedCode);
      final item = await _repository.submitPairingCode(normalizedCode);
      final hintedInstallationId = item.peer?.id.trim() ?? '';
      if (hintedInstallationId.isNotEmpty) {
        _torkaInstallationIdHint = hintedInstallationId;
      }
      // Publish the concrete outbox returned by the refresh to AppState;
      // refreshing the repository alone leaves the UI with the old list.
      await refreshData(forcePairing: true, allowAutoTorka: false);
      state = state.copyWith(
        action: '',
        notice: 'Zaproszenie wysłane. Oczekuje na akceptację.',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  Future<InviteCode?> refreshInviteCode() async {
    try {
      state = state.copyWith(
        action: OperationAction.refreshPairing,
        error: '',
        notice: 'Pobieranie kodu z relaya…',
      );
      final code = await _repository.refreshInviteCode();
      if (code != null) {
        state = state.copyWith(
          ownInvite: code,
          action: '',
          error: '',
          notice: '',
        );
      } else {
        state = state.copyWith(
          action: '',
          notice: '',
          error: 'Relay nie zwrócił kodu zaproszenia. Spróbuj ponownie.',
        );
      }
      return code;
    } catch (error) {
      state = state.copyWith(action: '', notice: '', error: _message(error));
      return null;
    }
  }

  Future<void> acceptPairing(String id) async {
    await _runAction(OperationAction.acceptPairing, () async {
      await _repository.acceptPairing(id);
    });
  }

  Future<void> rejectPairing(String id) async {
    await _runAction(OperationAction.rejectPairing, () async {
      await _repository.rejectPairing(id);
    });
  }

  Future<void> archiveInvite(String id) async {
    await _runAction(
      OperationAction.archivePairing,
      () => _repository.archiveInvite(id),
    );
  }

  Future<void> cancelPairing(String id) async {
    await _runAction(OperationAction.cancelPairing, () async {
      await _repository.cancelPairing(id);
    });
  }

  Future<void> verifyContact(String id) async {
    await _runAction(
      OperationAction.verifyContact,
      () => _repository.verifyContact(id),
    );
  }

  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) async {
    try {
      await _repository.updateContactSettings(
        contact.id,
        localAlias: localAlias,
        muted: muted,
        blocked: blocked,
        transportPolicy: transportPolicy,
      );
      await _repository.contacts();
      state = state.copyWith(error: '');
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> _runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    state = state.copyWith(action: action, error: '', notice: '');
    try {
      await operation();
      await refreshData();
      state = state.copyWith(action: '', notice: 'Gotowe.');
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  String _message(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return _localizedRuntimeError(message);
      }
      return switch (error.code) {
        'RUNTIME' =>
          'Operacja nie jest jeszcze dostępna. Poczekaj na połączenie z relayem.',
        _ => 'Operacja nie powiodła się (${error.code}).',
      };
    }
    return _localizedRuntimeError(
      error
          .toString()
          .replaceFirst('Exception: ', '')
          .replaceFirst('Bad state: ', ''),
    );
  }

  String _localizedRuntimeError(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('active pairing request already exists')) {
      return 'Inne zaproszenie nadal oczekuje. Anuluj je albo poczekaj na wygaśnięcie.';
    }
    if (normalized.contains('pairing code expired or invalid')) {
      return 'Kod parowania jest nieprawidłowy albo wygasł. Poproś kontakt o nowy kod.';
    }
    if (normalized.contains('cannot pair with yourself')) {
      return 'Nie możesz dodać własnego kodu parowania.';
    }
    if (normalized.contains(
      'a pending invitation to this user already exists',
    )) {
      return 'Zaproszenie do tego kontaktu już oczekuje.';
    }
    if (normalized.contains('too many pairing attempts')) {
      return 'Zbyt wiele prób parowania. Poczekaj chwilę i spróbuj ponownie.';
    }
    if (normalized.contains('pairing request not found')) {
      return 'To zaproszenie wygasło albo zostało już obsłużone.';
    }
    if (normalized.contains('invalid welcome signature') ||
        normalized.contains('identity') &&
            normalized.contains('does not match') ||
        normalized.contains('signature is invalid')) {
      return 'Nie udało się potwierdzić tożsamości drugiej strony. Zaproszenie zostało odrzucone.';
    }
    if (normalized.contains('peer endpoint') &&
        normalized.contains('missing')) {
      return 'Kontakt nie przekazał jeszcze zweryfikowanego endpointu P2P.';
    }
    if (normalized.contains('peer endpoint') &&
        (normalized.contains('invalid') ||
            normalized.contains('expired') ||
            normalized.contains('stale'))) {
      return 'Endpoint P2P kontaktu jest nieprawidłowy albo wygasł.';
    }
    if (normalized.contains('contact') &&
        (normalized.contains('already exists') ||
            normalized.contains('already a contact'))) {
      return 'Ten kontakt już istnieje.';
    }
    if (normalized.contains('acknowledgement') &&
        (normalized.contains('missing') || normalized.contains('timed out'))) {
      return 'Brak potwierdzenia drugiej strony. Spróbuj ponownie po odzyskaniu połączenia.';
    }
    if (normalized.contains('relay transport error')) {
      return 'Relay onion jest chwilowo niedostępny. Spróbuj ponownie za chwilę.';
    }
    return message;
  }

  bool get _devTorkaEnabled =>
      kDebugMode &&
      _effectiveDevTorkaPairingCode.length == 8 &&
      _effectiveDevTorkaPairingCode.runes.every(
        (value) => value >= 0x30 && value <= 0x39,
      );

  String get _effectiveDevTorkaPairingCode {
    final override = debugTorkaPairingCodeOverride?.trim() ?? '';
    if (override.isNotEmpty) {
      return override;
    }
    return _devTorkaPairingCode;
  }

  bool _isTorkaContact(ContactRecord contact) {
    final identifiers = <String>{
      contact.displayName.trim().toLowerCase(),
      contact.nickname.trim().toLowerCase(),
      contact.localAlias?.trim().toLowerCase() ?? '',
    };
    return identifiers.contains('torka') ||
        identifiers.contains('peer-torka') ||
        (_torkaInstallationIdHint != null &&
            contact.id == _torkaInstallationIdHint);
  }

  bool _isTorkaPairingItem(PairingItem item) {
    final peer = item.peer;
    if (peer != null) {
      return _isTorkaContact(peer);
    }
    return false;
  }

  Future<void> _cancelBlockingTorkaOutboxIfNeeded(String code) async {
    if (!_devTorkaEnabled || code == _effectiveDevTorkaPairingCode) {
      return;
    }
    final outstanding = state.outbox
        .where(
          (item) =>
              item.status == InviteState.pending ||
              item.status == InviteState.accepted,
        )
        .toList(growable: false);
    if (outstanding.length != 1 || !_isTorkaPairingItem(outstanding.single)) {
      return;
    }
    await _repository.cancelPairing(outstanding.single.id);
  }

  Future<void> _maybeAutoPairTorka() async {
    if (!_devTorkaEnabled ||
        _torkaPairingInFlight ||
        state.profile.nickname.trim().length < 2 ||
        !state.transport.connected) {
      return;
    }
    final torka = state.contacts.firstOrNullWhere(_isTorkaContact);
    if (torka != null) {
      _stopTorkaWatchdog();
      await _maybeEnsureTorkaConversation(torka);
      return;
    }
    final hasOutstandingOutbox = state.outbox.any(
      (item) =>
          item.status == InviteState.pending ||
          item.status == InviteState.accepted,
    );
    if (hasOutstandingOutbox) {
      _ensureTorkaWatchdog();
      return;
    }
    _torkaPairingInFlight = true;
    try {
      final item = await _repository.submitPairingCode(
        _effectiveDevTorkaPairingCode,
      );
      final hintedInstallationId = item.peer?.id.trim() ?? '';
      if (hintedInstallationId.isNotEmpty) {
        _torkaInstallationIdHint = hintedInstallationId;
      }
      // Refresh the concrete outbox after submitting. A plain application
      // snapshot contains only pending counts and would leave the watchdog
      // believing that no Torka request exists, causing repeated submits.
      await refreshData(forcePairing: true, allowAutoTorka: false);
      _ensureTorkaWatchdog(immediate: true);
    } catch (error) {
      final message = _message(error).toLowerCase();
      if (!message.contains('zaproszenie do tego kontaktu już oczekuje') &&
          !message.contains('inne zaproszenie nadal oczekuje') &&
          !message.contains('kod parowania jest nieprawidłowy')) {
        state = state.copyWith(
          notice: 'Torka pairing deferred: ${_message(error)}',
        );
      }
    } finally {
      _torkaPairingInFlight = false;
    }
  }

  Duration get _torkaWatchdogInterval =>
      // Tor publishes the relay endpoint before a freshly created onion
      // descriptor is necessarily reachable.  The shared engine owns the
      // connection retry cadence, so the UI only needs to observe it without
      // creating a burst of pairing refreshes.  Five seconds keeps the
      // contact list responsive while allowing the normal five-minute startup
      // window to complete.
      debugTorkaWatchdogIntervalOverride ?? const Duration(seconds: 5);

  int get _torkaWatchdogMaxAttempts =>
      // 60 x 5 seconds = the same bounded five-minute window used by the
      // sequential startup gate.  The old 18 x 2 seconds expired after only
      // 36 seconds, often before Torka had recovered its relay connection.
      debugTorkaWatchdogMaxAttemptsOverride ?? 60;

  void _ensureTorkaWatchdog({bool immediate = false}) {
    if (!_devTorkaEnabled) return;
    _torkaWatchdog ??= Timer.periodic(_torkaWatchdogInterval, (_) {
      unawaited(_runTorkaWatchdogTick());
    });
    if (immediate) {
      unawaited(_runTorkaWatchdogTick());
    }
  }

  void _stopTorkaWatchdog() {
    _torkaWatchdog?.cancel();
    _torkaWatchdog = null;
    _torkaWatchdogAttempts = 0;
  }

  bool get _hasOutstandingTorkaOutbox => state.outbox.any(
    (item) =>
        (item.status == InviteState.pending ||
            item.status == InviteState.accepted) &&
        _isTorkaPairingItem(item),
  );

  Future<void> _runTorkaWatchdogTick() async {
    if (!_devTorkaEnabled || !state.transport.connected) {
      _stopTorkaWatchdog();
      return;
    }
    if (_torkaPairingInFlight || _torkaConversationInFlight) {
      return;
    }

    final torka = state.contacts.firstOrNullWhere(_isTorkaContact);
    if (torka != null) {
      await _maybeEnsureTorkaConversation(torka);
      final exists = state.conversations.any(
        (conversation) => conversation.contactId == torka.id,
      );
      if (exists) {
        _stopTorkaWatchdog();
      }
      return;
    }

    if (!_hasOutstandingTorkaOutbox) {
      _stopTorkaWatchdog();
      return;
    }

    _torkaWatchdogAttempts += 1;
    if (_torkaWatchdogAttempts > _torkaWatchdogMaxAttempts) {
      _stopTorkaWatchdog();
      state = state.copyWith(
        notice:
            'Torka pairing timeout: kontakt nie potwierdził się jeszcze w runtime.',
      );
      return;
    }

    try {
      await refreshData(forcePairing: true, allowAutoTorka: false);
    } catch (_) {
      // Best-effort background recovery only.
    }
  }

  Future<void> _maybeEnsureTorkaConversation(ContactRecord contact) async {
    if (_torkaConversationInFlight) return;
    final exists = state.conversations.any(
      (conversation) => conversation.contactId == contact.id,
    );
    if (exists) return;
    _torkaConversationInFlight = true;
    try {
      await _repository.startConversation(contact.id);
      // The conversation mutation is committed by the engine, but the
      // controller state is a separate projection. Refresh that projection
      // explicitly so the new chat appears without leaving/re-entering the
      // screen. Suppress the watchdog recursion for this refresh.
      await refreshData(allowAutoTorka: false);
    } catch (_) {
      // Torka conversation bootstrap is best-effort in local dev only.
    } finally {
      _torkaConversationInFlight = false;
    }
  }

  List<StartupStep> _startupSteps(
    List<StartupStep> current,
    StartupStepKind kind,
    StartupStepState stepState,
    String detail,
  ) {
    return transitionStartupStep(current, kind, stepState, detail);
  }

  List<StartupStep> _startupStepsForEndpoint(
    List<StartupStep> current,
    bool available, {
    required bool torReady,
    required bool relayReady,
    required PeerServerStatus peerServerStatus,
  }) {
    if (!available) {
      final failed =
          peerServerStatus == PeerServerStatus.offline ||
          peerServerStatus == PeerServerStatus.error;
      var waiting = _startupSteps(
        current,
        StartupStepKind.peerListener,
        failed
            ? StartupStepState.error
            : torReady
            ? StartupStepState.running
            : StartupStepState.pending,
        failed
            ? 'Lokalny listener P2P nie jest gotowy'
            : torReady
            ? 'Oczekiwanie na lokalny endpoint P2P'
            : 'Tor lokalny jeszcze nie jest gotowy',
      );
      waiting = _startupSteps(
        waiting,
        StartupStepKind.onionService,
        failed
            ? StartupStepState.error
            : torReady
            ? StartupStepState.running
            : StartupStepState.pending,
        failed
            ? 'Usługa onion P2P nie jest dostępna'
            : torReady
            ? 'Oczekiwanie na adres onion P2P'
            : 'Tor lokalny jeszcze nie jest gotowy',
      );
      return _startupSteps(
        waiting,
        StartupStepKind.communication,
        failed ? StartupStepState.error : StartupStepState.pending,
        failed
            ? 'Komunikacja nie jest gotowa bez endpointu P2P'
            : 'Oczekiwanie na endpoint P2P',
      );
    }
    var steps = _startupSteps(
      current,
      StartupStepKind.peerListener,
      StartupStepState.ready,
      'Lokalny listener działa',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.onionService,
      StartupStepState.ready,
      'Adres onion jest dostępny',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.communication,
      relayReady ? StartupStepState.ready : StartupStepState.pending,
      relayReady
          ? 'Komunikacja jest gotowa'
          : 'Endpoint P2P gotowy · oczekiwanie na relay',
    );
    return steps;
  }

  ControllerScreen _screenAfterConnect(
    RuntimeProfile profile,
    RuntimeTorStatus transport, {
    List<StartupStep>? startupSteps,
    PeerServerStatus? peerServerStatus,
  }) {
    final steps = startupSteps ?? state.startupSteps;
    final localPeerServerStatus = peerServerStatus ?? state.peerServerStatus;
    final startupReady =
        transport.connected &&
        localPeerServerStatus == PeerServerStatus.ready &&
        steps.length == StartupStepKind.values.length &&
        steps.every((step) => step.state == StartupStepState.ready);

    // The application is usable only after both its local onion service and
    // the control-plane relay are ready.  This keeps a half-started client on
    // the explicit diagnostic timeline instead of opening an unusable shell.
    if (!startupReady) return ControllerScreen.boot;
    if (profile.nickname.trim().isNotEmpty) return ControllerScreen.main;
    return ControllerScreen.nickname;
  }

  PeerServerStatus _peerServerStatusForRefresh(
    RuntimeTorStatus transport,
    bool peerEndpointAvailable, {
    required PeerServerStatus current,
  }) {
    // Local onion availability is independent of relay connectivity.  A
    // cold relay circuit must not turn an already published local P2P service
    // back into "starting".
    if (peerEndpointAvailable) {
      return PeerServerStatus.ready;
    }
    if (transport.failed) {
      return PeerServerStatus.error;
    }
    if (!transport.usable) {
      return PeerServerStatus.starting;
    }
    if (current == PeerServerStatus.offline ||
        current == PeerServerStatus.error) {
      return current;
    }
    return PeerServerStatus.starting;
  }
}
