import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/application_state/application_snapshot.dart';
import '../core/application_state/application_state_store.dart';
import '../core/connection/app_state_connection.dart';
import '../core/connection/connection_readiness.dart';
import '../core/runtime/runtime_repository.dart';
import '../locales/domain/user_problem.dart';
import '../locales/domain/user_problem_code.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
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
    this.problem,
    this.typingContacts = const {},
    this.lastSeenEnabled = true,
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
  List<PairingItem> get inbox => pairingInboxItems;
  List<PairingItem> get outbox => pairingOutboxItems;
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
  final UserProblem? problem;
  final Map<String, bool> typingContacts;
  final bool lastSeenEnabled;

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
    UserProblem? problem,
    bool clearProblem = false,
    Map<String, bool>? typingContacts,
    bool? lastSeenEnabled,
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
    problem:
        problem ??
        (clearProblem || (error != null && error.isEmpty)
            ? null
            : this.problem),
    typingContacts: typingContacts ?? this.typingContacts,
    lastSeenEnabled: lastSeenEnabled ?? this.lastSeenEnabled,
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
      unawaited(_repository.dispose());
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
    state = state.copyWith(error: '');
    try {
      await _repository.connect();
      await _repository.refresh(includePairing: true, bypassCooldown: true);
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> setNickname(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      final snapshot = state.applicationSnapshot;
      state = state.copyWith(
        applicationSnapshot: snapshot?.copyWith(profile: profile),
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
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
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
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> openOrStartConversation(ContactRecord contact) async {
    state = state.copyWith(
      destination: MainDestination.chats,
      action: OperationAction.startConversation,
      error: '',
    );
    try {
      final activated = await _repository.activateConversation(contact.id);
      state = state.copyWith(
        selectedConversationId: activated.conversation.id,
        action: '',
      );
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
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
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
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
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
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
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> setTyping(bool typing) async {
    final conversationId = state.selectedConversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!(preferences.getBool('torchat.privacy.typing') ?? true)) return;
      await _repository.setTyping(conversationId, typing);
    } catch (_) {
      // Best-effort transient signal.
    }
  }

  Future<void> setConversationFocus(String conversationId, bool focused) async {
    final result = await _repository.setConversationFocus(
      conversationId,
      focused,
    );
    if (result?.status == ReadReceiptQueueStatus.error) {
      state = state.copyWith(
        error: 'Unable to queue read receipt: ${result!.error}',
        problem: const UserProblem(code: UserProblemCode.operationFailed),
      );
    }
  }

  Future<void> updateVisibility(bool foreground) async {
    final conversationId = state.selectedConversationId;
    if (!foreground && conversationId != null) {
      await _repository.setConversationFocus(conversationId, false);
    }
    await _repository.updateAppVisibility(foreground);
    if (foreground && conversationId != null) {
      await _repository.setConversationFocus(conversationId, true);
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final enabled = preferences.getBool('torchat.privacy.presence') ?? true;
      await _repository.setPresence(foreground && enabled);
    } catch (_) {
      // Best-effort presence update.
    }
  }

  Future<void> submitPairingCode(String code) async {
    if (!state.transport.connected ||
        !state.connectionReadiness.canPerform(ConnectionOperation.pair)) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.connectionUnavailable),
      );
      return;
    }
    final profile = await _repository.profile(force: true);
    final snapshot = state.applicationSnapshot;
    if (snapshot != null && snapshot.profile != profile) {
      state = state.copyWith(
        applicationSnapshot: snapshot.copyWith(profile: profile),
      );
    }
    if (profile.nickname.trim().length < 2) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.nicknameRequired),
      );
      return;
    }
    final normalizedCode = pairingCode(code);
    if (normalizedCode == null) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.pairingCodeInvalid),
      );
      return;
    }
    state = state.copyWith(action: OperationAction.submitPairing, error: '');
    try {
      await _cancelBlockingTorkaOutboxIfNeeded(normalizedCode);
      final item = await _repository.submitPairingCode(normalizedCode);
      final hintedInstallationId = item.peer?.id.trim() ?? '';
      if (hintedInstallationId.isNotEmpty) {
        _torkaInstallationIdHint = hintedInstallationId;
      }
      await refreshData(forcePairing: true, allowAutoTorka: false);
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<InviteCode?> refreshInviteCode({bool quietWhenPending = false}) async {
    if (!state.connectionReadiness.canPerform(ConnectionOperation.pair)) {
      if (!quietWhenPending) {
        state = state.copyWith(
          action: '',
          error: '',
          problem: const UserProblem(
            code: UserProblemCode.secureConnectionPending,
          ),
        );
      }
      return null;
    }
    try {
      state = state.copyWith(action: OperationAction.refreshPairing, error: '');
      final code = await _repository.refreshInviteCode();
      if (code != null) {
        state = state.copyWith(ownInvite: code, action: '', error: '');
      } else {
        state = state.copyWith(
          action: '',
          error: '',
          problem: const UserProblem(
            code: UserProblemCode.inviteCodeUnavailable,
          ),
        );
      }
      return code;
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
      return null;
    }
  }

  Future<void> acceptPairing(String id) async {
    await _runAction(OperationAction.acceptPairing, () async {
      await _repository.acceptPairing(id);
    }, refreshPairing: true);
  }

  Future<void> rejectPairing(String id) async {
    await _runAction(OperationAction.rejectPairing, () async {
      await _repository.rejectPairing(id);
    }, refreshPairing: true);
  }

  Future<void> archiveInvite(String id) async {
    await _runAction(
      OperationAction.archivePairing,
      () => _repository.archiveInvite(id),
      refreshPairing: true,
    );
  }

  Future<void> cancelPairing(String id) async {
    await _runAction(OperationAction.cancelPairing, () async {
      await _repository.cancelPairing(id);
    }, refreshPairing: true);
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
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _runAction(
    String action,
    Future<void> Function() operation, {
    bool refreshPairing = false,
  }) async {
    state = state.copyWith(action: action, error: '');
    try {
      await operation();
      await refreshData(forcePairing: refreshPairing);
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  String _message(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
      return 'Platform operation failed (${error.code}).';
    }
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '');
  }

  UserProblem problemForError(Object error) {
    final normalized = error.toString().toLowerCase();
    final code = normalized.contains('pairing code expired') ||
            normalized.contains('pairing code expired or invalid')
        ? UserProblemCode.pairingCodeInvalid
        : normalized.contains('stale welcome') ||
              normalized.contains('old invitation') ||
              normalized.contains('pairing request not found') ||
              normalized.contains('invalid welcome signature') ||
              normalized.contains('signature is invalid') ||
              (normalized.contains('identity') &&
                  normalized.contains('does not match'))
        ? UserProblemCode.pairingWelcomeStale
        : normalized.contains('relay transport error') ||
              normalized.contains('gateway')
        ? UserProblemCode.pairingGatewayUnavailable
        : normalized.contains('connection') ||
              normalized.contains('tor') ||
              normalized.contains('acknowledgement') ||
              normalized.contains('peer endpoint')
        ? UserProblemCode.connectionUnavailable
        : UserProblemCode.operationFailed;
    return UserProblem(code: code, arguments: {'raw': error.toString()});
  }

  bool get _devTorkaEnabled =>
      kDebugMode && isPairingCode(_effectiveDevTorkaPairingCode);

  String get _effectiveDevTorkaPairingCode {
    final override = debugTorkaPairingCodeOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return '';
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
    return peer != null && _isTorkaContact(peer);
  }

  Future<void> _cancelBlockingTorkaOutboxIfNeeded(String code) async {
    if (!_devTorkaEnabled) return;
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
      await refreshData(forcePairing: true, allowAutoTorka: false);
      _ensureTorkaWatchdog(immediate: true);
    } catch (error) {
      final message = _message(error).toLowerCase();
      if (!message.contains('pending invitation') &&
          !message.contains('active pairing request already exists') &&
          !message.contains('pairing code expired or invalid')) {
        debugPrint('Torka pairing deferred: ${_message(error)}');
      }
    } finally {
      _torkaPairingInFlight = false;
    }
  }

  Duration get _torkaWatchdogInterval =>
      debugTorkaWatchdogIntervalOverride ?? const Duration(seconds: 5);

  int get _torkaWatchdogMaxAttempts =>
      debugTorkaWatchdogMaxAttemptsOverride ?? 60;

  void _ensureTorkaWatchdog({bool immediate = false}) {
    if (!_devTorkaEnabled) return;
    _torkaWatchdog ??= Timer.periodic(_torkaWatchdogInterval, (_) {
      unawaited(_runTorkaWatchdogTick());
    });
    if (immediate) unawaited(_runTorkaWatchdogTick());
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
    if (_torkaPairingInFlight || _torkaConversationInFlight) return;

    final torka = state.contacts.firstOrNullWhere(_isTorkaContact);
    if (torka != null) {
      await _maybeEnsureTorkaConversation(torka);
      final exists = state.conversations.any(
        (conversation) => conversation.contactId == torka.id,
      );
      if (exists) _stopTorkaWatchdog();
      return;
    }

    if (!_hasOutstandingTorkaOutbox) {
      _stopTorkaWatchdog();
      return;
    }

    _torkaWatchdogAttempts += 1;
    if (_torkaWatchdogAttempts > _torkaWatchdogMaxAttempts) {
      _stopTorkaWatchdog();
      debugPrint(
        'Torka pairing timeout: contact is not confirmed in runtime yet.',
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
      await refreshData(allowAutoTorka: false);
    } catch (_) {
      // Local development helper only.
    } finally {
      _torkaConversationInFlight = false;
    }
  }

  List<StartupStep> _startupSteps(
    List<StartupStep> current,
    StartupStepKind kind,
    StartupStepState stepState,
    String detail,
  ) => transitionStartupStep(current, kind, stepState, detail);

  List<StartupStep> _startupStepsForEndpoint(
    List<StartupStep> current,
    bool available, {
    required bool torReady,
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
            ? 'Local P2P listener is not ready'
            : torReady
            ? 'Waiting for local P2P endpoint'
            : 'Local Tor is not ready yet',
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
            ? 'P2P onion service is unavailable'
            : torReady
            ? 'Waiting for P2P onion address'
            : 'Local Tor is not ready yet',
      );
      return _startupSteps(
        waiting,
        StartupStepKind.communication,
        failed ? StartupStepState.error : StartupStepState.pending,
        failed
            ? 'Communication is unavailable without a P2P endpoint'
            : 'Waiting for P2P endpoint',
      );
    }
    var steps = _startupSteps(
      current,
      StartupStepKind.peerListener,
      StartupStepState.ready,
      'Local listener is ready',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.onionService,
      StartupStepState.ready,
      'Onion address is available',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.communication,
      StartupStepState.ready,
      'Communication is ready',
    );
    return steps;
  }

  ControllerScreen _screenAfterConnect(
    RuntimeProfile profile,
    RuntimeTorStatus transport, {
    List<StartupStep>? startupSteps,
    PeerServerStatus? peerServerStatus,
  }) {
    final startupReady = state.connectionReadiness.localCoreReady;
    if (!startupReady) return ControllerScreen.boot;
    if (profile.nickname.trim().isNotEmpty) return ControllerScreen.main;
    return ControllerScreen.nickname;
  }

  PeerServerStatus _peerServerStatusForRefresh(
    RuntimeTorStatus transport,
    bool peerEndpointAvailable, {
    required PeerServerStatus current,
  }) {
    if (peerEndpointAvailable) return PeerServerStatus.ready;
    if (transport.failed) return PeerServerStatus.error;
    if (!transport.usable) return PeerServerStatus.starting;
    if (current == PeerServerStatus.offline ||
        current == PeerServerStatus.error) {
      return current;
    }
    return PeerServerStatus.starting;
  }
}
