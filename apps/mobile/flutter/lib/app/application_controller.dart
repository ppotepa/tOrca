import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_flutter_ui/async/async_operation_state.dart';
import '../core/runtime/message_paging.dart';

import '../client_runtime.dart';
import '../core/connection/app_state_connection.dart';
import '../core/connection/connection_readiness.dart';
import '../core/presence/contact_presence_store.dart';
import '../core/problems/runtime_problem.dart';
import '../core/problems/runtime_problem_classifier.dart';
import '../core/problems/runtime_problem_from_error.dart';
import '../core/runtime/runtime_repository.dart';
import '../locales/domain/user_problem.dart';
import '../locales/domain/user_problem_code.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';
import 'application_notification_coordinator.dart';
import 'application_runtime_coordinator.dart';
import 'application_state.dart';
import 'ui_operation_registry.dart';

export '../core/connection/app_state_connection.dart';
export 'application_state.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
);

class ApplicationController extends Notifier<AppState> with UiOperationRunner {
  late final ClientRuntime _runtime;
  late final RuntimeRepository _repository;
  late final ApplicationRuntimeCoordinator _runtimeCoordinator;
  late final ApplicationNotificationCoordinator _notifications;

  @override
  Ref get operationRef => ref;

  @override
  AppState build() {
    _runtime = ref.watch(clientRuntimeProvider);
    _repository = ref.watch(runtimeRepositoryProvider);
    final presence = ref.read(contactPresenceStoreProvider);
    _notifications = ApplicationNotificationCoordinator(
      repository: _repository,
      readState: () => state,
      writeState: (next) => state = next,
    );
    _runtimeCoordinator = ApplicationRuntimeCoordinator(
      runtime: _runtime,
      repository: _repository,
      contactPresence: presence,
      readState: () => state,
      writeState: (next) => state = next,
      refreshCore: _refreshDataCore,
      messageForError: _message,
      problemForError: problemForError,
      handleSideEffects: _notifications.handleRuntimeEvent,
    );
    listenSelf((previous, next) {
      if (previous?.selectedConversationId != next.selectedConversationId) {
        unawaited(
          _notifications.persistActiveConversation(next.selectedConversationId),
        );
      }
    });
    ref.onDispose(() {
      _runtimeCoordinator.dispose();
      unawaited(_repository.dispose());
    });
    return const AppState();
  }

  Future<void> initialize() async {
    await _notifications.prepare();
    await _runtimeCoordinator.initialize();
    await _notifications.persistActiveConversation(
      state.selectedConversationId,
    );
    _notifications.hideRemovedRelationships();
  }

  Future<void> refreshData() async {
    await _runtimeCoordinator.refreshData();
    _notifications.hideRemovedRelationships();
  }

  Future<void> retryTor() => runUiOperation(
    UiOperationKey.connectionRetry,
    'Retrying connection',
    _runtimeCoordinator.retryTor,
  );

  void reattachPresence() => _runtimeCoordinator.reattachPresence();

  Future<OlderMessagesResult> loadOlderMessages(String conversationId) =>
      _notifications.loadOlderMessages(conversationId);

  Future<void> _refreshDataCore() async {
    final snapshot = await _repository.refresh(bypassCooldown: true);
    final applicationSnapshot = snapshot.application;
    final peerEndpointAvailable = snapshot.local.peerEndpointAvailable;
    final peerServerStatus = _peerServerStatusForRefresh(
      state.transport,
      peerEndpointAvailable,
      current: state.peerServerStatus,
    );
    state = state.copyWith(
      applicationSnapshot: applicationSnapshot,
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
    }
  }

  Future<T> _runPresented<T>(
    String key,
    String label,
    Future<T> Function() operation, {
    String? targetId,
    bool throwOnFailure = false,
  }) async {
    final notifier = ref.read(uiOperationProvider(key).notifier);
    notifier.state = AsyncOperationState(
      phase: AsyncOperationPhase.running,
      label: label,
      targetId: targetId,
    );
    try {
      final value = await operation();
      final error = state.error.trim();
      notifier.state = AsyncOperationState(
        phase: error.isEmpty
            ? AsyncOperationPhase.succeeded
            : AsyncOperationPhase.failed,
        label: label,
        targetId: targetId,
        error: error,
      );
      if (throwOnFailure && error.isNotEmpty) {
        throw StateError(error);
      }
      return value;
    } catch (error) {
      notifier.state = AsyncOperationState(
        phase: AsyncOperationPhase.failed,
        label: label,
        targetId: targetId,
        error: error.toString(),
      );
      rethrow;
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
    final runtimeProblem = runtimeProblemFromError(error);
    final classification = classifyRuntimeProblem(runtimeProblem);
    final code = switch (runtimeProblem.code) {
      RuntimeErrorCode.invalidInput => UserProblemCode.pairingCodeInvalid,
      RuntimeErrorCode.transportUnavailable ||
      RuntimeErrorCode.temporarilyUnavailable =>
        UserProblemCode.connectionUnavailable,
      RuntimeErrorCode.notFound ||
      RuntimeErrorCode.conflict => UserProblemCode.operationFailed,
      RuntimeErrorCode.storageFailed ||
      RuntimeErrorCode.cryptoFailed ||
      RuntimeErrorCode.unsupported ||
      RuntimeErrorCode.internal =>
        classification.disposition == RuntimeProblemDisposition.connectionStatus
            ? UserProblemCode.connectionUnavailable
            : UserProblemCode.operationFailed,
    };
    return UserProblem(
      code: code,
      arguments: {
        'runtimeCode': runtimeProblem.code.wireValue,
        'runtimeCategory': runtimeProblem.category.wireValue,
        if (runtimeProblem.operationId != null)
          'operationId': runtimeProblem.operationId!,
        if (runtimeProblem.entityId != null)
          'entityId': runtimeProblem.entityId!,
      },
    );
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

  Future<void> setNickname(String nickname) => _runPresented(
    UiOperationKey.nicknameSave,
    'Saving nickname',
    () => _setNicknameCore(nickname),
  );

  Future<void> openConversation(String id) => _runPresented(
    UiOperationKey.conversationOpen(id),
    'Opening conversation',
    () => _openConversationCore(id),
    targetId: id,
  );

  Future<void> openOrStartConversation(ContactRecord contact) => _runPresented(
    UiOperationKey.conversationStart(contact.id),
    'Starting conversation',
    () => _openOrStartConversationCore(contact),
    targetId: contact.id,
  );

  Future<void> sendMessage(String text, {String? replyToMessageId}) {
    final id = state.selectedConversationId ?? '';
    return _runPresented(
      UiOperationKey.messageSend(id),
      'Sending message',
      () => _sendMessageCore(text, replyToMessageId: replyToMessageId),
      targetId: id,
    );
  }

  Future<void> retryMessage(String messageId) => _runPresented(
    UiOperationKey.messageRetry(messageId),
    'Retrying message',
    () => _retryMessageCore(messageId),
    targetId: messageId,
  );

  Future<void> deleteMessageLocal(String messageId) => _runPresented(
    UiOperationKey.messageDelete(messageId),
    'Deleting message',
    () => _deleteMessageLocalCore(messageId),
    targetId: messageId,
  );

  Future<void> submitPairingCode(String code) => _runPresented(
    UiOperationKey.pairingSubmit,
    'Submitting pairing code',
    () => _submitPairingCodeCore(code),
  );

  Future<InviteCode?> refreshInviteCode({bool quietWhenPending = false}) =>
      _runPresented(
        UiOperationKey.inviteCodeLoad,
        'Loading pairing code',
        () => _refreshInviteCodeCore(quietWhenPending: quietWhenPending),
      );

  Future<void> acceptPairing(String id) => _runPresented(
    UiOperationKey.pairingAccept(id),
    'Accepting invitation',
    () => _acceptPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> rejectPairing(String id) => _runPresented(
    UiOperationKey.pairingReject(id),
    'Rejecting invitation',
    () => _rejectPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> archiveInvite(String id) => _runPresented(
    UiOperationKey.pairingArchive(id),
    'Archiving invitation',
    () => _archiveInviteCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> cancelPairing(String id) => _runPresented(
    UiOperationKey.pairingCancel(id),
    'Cancelling invitation',
    () => _cancelPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> verifyContact(String id) => _runPresented(
    UiOperationKey.contactVerify(id),
    'Verifying contact',
    () => _verifyContactCore(id),
    targetId: id,
  );

  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) => _runPresented(
    UiOperationKey.contactSettingsFor(contact.id),
    'Saving contact settings',
    () => _updateContactSettingsCore(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    ),
    targetId: contact.id,
  );

  Future<void> _setNicknameCore(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: state.peerServerStatus,
        ),
        error: '',
      );
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

  Future<void> _openConversationCore(String id) async {
    try {
      final conversation = state.conversations.firstOrNullWhere(
        (item) => item.id == id || item.contactId == id,
      );
      final activated = await _repository.activateConversation(
        conversation?.contactId ?? id,
      );
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
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

  Future<void> _openOrStartConversationCore(ContactRecord contact) async {
    state = state.copyWith(
      destination: MainDestination.chats,
      action: OperationAction.startConversation,
      error: '',
    );
    try {
      final activated = await _repository.activateConversation(contact.id);
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
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

  Future<void> _sendMessageCore(String text, {String? replyToMessageId}) async {
    final id = state.selectedConversationId;
    if (id == null || text.trim().isEmpty) return;
    state = state.copyWith(action: OperationAction.sendMessage, error: '');
    try {
      await _repository.sendMessage(
        id,
        text.trim(),
        replyToMessageId: replyToMessageId,
      );
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
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

  Future<void> _retryMessageCore(String messageId) async {
    try {
      await _repository.retryMessage(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
      }
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _deleteMessageLocalCore(String messageId) async {
    try {
      await _repository.deleteMessageLocal(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
      }
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
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

  Future<void> _submitPairingCodeCore(String code) async {
    if (!state.transport.connected ||
        !state.connectionReadiness.canPerform(ConnectionOperation.pair)) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.connectionUnavailable),
      );
      return;
    }
    final profile = await _repository.profile(force: true);
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
      await _repository.submitPairingCode(normalizedCode);
      await refreshData();
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<InviteCode?> _refreshInviteCodeCore({
    bool quietWhenPending = false,
  }) async {
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

  Future<void> _acceptPairingCore(String id) async {
    await _runAction(OperationAction.acceptPairing, () async {
      await _repository.acceptPairing(id);
    });
  }

  Future<void> _rejectPairingCore(String id) async {
    await _runAction(OperationAction.rejectPairing, () async {
      await _repository.rejectPairing(id);
    });
  }

  Future<void> _archiveInviteCore(String id) async {
    await _runAction(
      OperationAction.archivePairing,
      () => _repository.archiveInvite(id),
    );
  }

  Future<void> _cancelPairingCore(String id) async {
    await _runAction(OperationAction.cancelPairing, () async {
      await _repository.cancelPairing(id);
    });
  }

  Future<void> _verifyContactCore(String id) async {
    await _runAction(
      OperationAction.verifyContact,
      () => _repository.verifyContact(id),
    );
  }

  Future<void> _updateContactSettingsCore(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) async {
    final preserveHistory = await _notifications.preserveHistoryForBlock(
      contact,
      blocked,
    );
    try {
      await _repository.updateContactSettings(
        contact.id,
        localAlias: localAlias,
        muted: muted,
        blocked: blocked,
        transportPolicy: transportPolicy,
      );
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
      if (blocked && !contact.blocked) {
        await _repository.removeRelationship(
          contact.id,
          preserveHistory: preserveHistory,
        );
        await refreshData();
      }
      _notifications.hideRemovedRelationships();
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    state = state.copyWith(action: action, error: '');
    try {
      await operation();
      await refreshData();
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }
}
