import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_flutter_ui/async/async_operation_state.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_flutter_ui/core/runtime/message_paging.dart';
import 'package:torchat_flutter_ui/core/runtime/runtime_repository_models.dart';

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
import '../platform/platform_services.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';
import 'application_notification_coordinator.dart';
import 'application_runtime_coordinator.dart';
import 'application_state.dart';
import 'ui_operation_registry.dart';

export '../core/connection/app_state_connection.dart';
export 'application_state.dart';

part 'application_controller_commands.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
);

class ApplicationController extends Notifier<AppState>
    with UiOperationRunner {
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
        unawaited(_notifications.persistActiveConversation(
          next.selectedConversationId,
        ));
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
    await _notifications.persistActiveConversation(state.selectedConversationId);
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
      RuntimeErrorCode.notFound || RuntimeErrorCode.conflict =>
        UserProblemCode.operationFailed,
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
        if (runtimeProblem.entityId != null) 'entityId': runtimeProblem.entityId!,
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
}
