import '../models/domain.dart';
import 'connection_component.dart';
import 'sequential_connection_sequence.dart';

class ConnectionReadiness {
  const ConnectionReadiness({
    required this.engine,
    required this.localData,
    required this.tor,
    required this.peerListener,
    required this.onionService,
    required this.communicationCommitted,
    required this.communicationDetail,
  });

  factory ConnectionReadiness.fromRuntime({
    required RuntimeTorStatus transport,
    Map<TransportComponent, TransportStatusSnapshot> transportStatuses =
        const {},
    required PeerServerStatus peerServerStatus,
    required List<StartupStep> startupSteps,
    required bool localDataReady,
  }) {
    final engineStep = _step(startupSteps, StartupStepKind.engine);
    final localDataStep = _step(startupSteps, StartupStepKind.localData);
    final torStep = _step(startupSteps, StartupStepKind.tor);
    final peerListenerStep = _step(startupSteps, StartupStepKind.peerListener);
    final onionStep = _step(startupSteps, StartupStepKind.onionService);
    final communicationStep = _step(
      startupSteps,
      StartupStepKind.communication,
    );

    // A successful identity read is authoritative even when the earlier
    // runtime-ready event arrived before Flutter attached to the event stream.
    final engineState = localDataReady
        ? ConnectionComponentState.ready
        : _fromStartupState(engineStep.state);
    final localDataState = engineState == ConnectionComponentState.failed
        ? ConnectionComponentState.failed
        : localDataReady
        ? ConnectionComponentState.ready
        : localDataStep.state == StartupStepState.error ||
              localDataStep.state == StartupStepState.blocked
        ? ConnectionComponentState.failed
        : localDataStep.state == StartupStepState.pending
        ? ConnectionComponentState.pending
        : ConnectionComponentState.starting;

    final raw = <ConnectionComponentStatus>[
      ConnectionComponentStatus(
        component: ConnectionComponent.engine,
        state: engineState,
        detail: engineStep.detail.isEmpty
            ? ConnectionComponent.engine.name
            : engineStep.detail,
      ),
      ConnectionComponentStatus(
        component: ConnectionComponent.localData,
        state: localDataState,
        detail: localDataReady
            ? 'Tożsamość i zaszyfrowane dane lokalne są gotowe'
            : engineState == ConnectionComponentState.failed
            ? engineStep.detail
            : localDataStep.detail.isNotEmpty
            ? localDataStep.detail
            : 'Odczytywanie tożsamości, profilu i lokalnego snapshotu',
      ),
      _gateByStartupStep(_torStatus(transport), torStep),
      _gateByStartupStep(
        _peerStatus(
          component: ConnectionComponent.peerListener,
          aggregate: peerServerStatus,
          step: peerListenerStep,
          allowReadyWhileAggregateStarts: true,
        ),
        peerListenerStep,
      ),
      _gateByStartupStep(
        _peerStatus(
          component: ConnectionComponent.onionService,
          aggregate: peerServerStatus,
          step: onionStep,
          allowReadyWhileAggregateStarts: false,
        ),
        onionStep,
      ),
    ];
    final sequential = sequentialConnectionStatuses(raw);

    return ConnectionReadiness(
      engine: sequential[0],
      localData: sequential[1],
      tor: sequential[2],
      peerListener: sequential[3],
      onionService: sequential[4],
      communicationCommitted: communicationStep.state == StartupStepState.ready,
      communicationDetail: communicationStep.detail,
    );
  }

  final ConnectionComponentStatus engine;
  final ConnectionComponentStatus localData;
  final ConnectionComponentStatus tor;
  final ConnectionComponentStatus peerListener;
  final ConnectionComponentStatus onionService;
  final bool communicationCommitted;
  final String communicationDetail;

  List<ConnectionComponentStatus> get components => [
    engine,
    localData,
    tor,
    peerListener,
    onionService,
  ];

  bool get localCoreReady => engine.ready && localData.ready;

  /// Capability gates for individual operations. Local reads must not depend
  /// on the control-plane relay or the local onion listener; network writes
  /// may be queued until one of their configured routes is available.
  bool canPerform(ConnectionOperation operation) => switch (operation) {
    ConnectionOperation.readLocalData => localCoreReady,
    ConnectionOperation.diagnose => localCoreReady,
    ConnectionOperation.pair => localCoreReady && tor.ready && onionService.ready,
    ConnectionOperation.sendP2p => localCoreReady && peerListener.ready,
  };

  bool get startupComponentsReady =>
      localCoreReady &&
      tor.ready &&
      peerListener.ready &&
      onionService.ready;

  bool get onboardingReady => localCoreReady;

  bool get communicationReady => onboardingReady;

  bool get busy =>
      !communicationReady &&
      (components.any((item) => item.busy) || startupComponentsReady);

  bool get degraded =>
      components.any((item) => item.state == ConnectionComponentState.degraded);

  bool get failed =>
      components.any((item) => item.state == ConnectionComponentState.failed);

  PeerServerStatus get peerServerStatus {
    if (peerListener.ready && onionService.ready) {
      return PeerServerStatus.ready;
    }
    if (peerListener.state == ConnectionComponentState.failed ||
        onionService.state == ConnectionComponentState.failed) {
      return PeerServerStatus.error;
    }
    if (peerListener.state == ConnectionComponentState.degraded ||
        onionService.state == ConnectionComponentState.degraded) {
      return PeerServerStatus.offline;
    }
    return PeerServerStatus.starting;
  }

  List<StartupStep> get startupSteps => [
    StartupStep(
      kind: StartupStepKind.engine,
      state: _toStartupState(engine.state),
      detail: engine.detail,
    ),
    StartupStep(
      kind: StartupStepKind.localData,
      state: _toStartupState(localData.state),
      detail: localData.detail,
    ),
    StartupStep(
      kind: StartupStepKind.tor,
      state: _toStartupState(tor.state),
      detail: tor.detail,
    ),
    StartupStep(
      kind: StartupStepKind.peerListener,
      state: _toStartupState(peerListener.state),
      detail: peerListener.detail,
    ),
    StartupStep(
      kind: StartupStepKind.onionService,
      state: _toStartupState(onionService.state),
      detail: onionService.detail,
    ),
    StartupStep(
      kind: StartupStepKind.communication,
      state: communicationReady
          ? StartupStepState.ready
          : failed
          ? StartupStepState.error
          : degraded
          ? StartupStepState.warning
          : StartupStepState.running,
      detail: communicationReady
          ? 'TorChat jest gotowy do komunikacji'
          : _communicationDetail(),
    ),
  ];

  String _communicationDetail() {
    if (startupComponentsReady) {
      return communicationDetail.isEmpty
          ? 'Finalizowanie gotowości komunikacji'
          : communicationDetail;
    }
    final firstBlocking = components.firstWhere(
      (item) => !item.ready,
      orElse: () => onionService,
    );
    if (firstBlocking.state == ConnectionComponentState.failed) {
      return '${firstBlocking.component.name}: ${firstBlocking.detail}';
    }
    if (firstBlocking.state == ConnectionComponentState.degraded) {
      return '${firstBlocking.component.name} degraded';
    }
    return 'Waiting: ${firstBlocking.component.name}';
  }
}

enum ConnectionOperation {
  readLocalData,
  diagnose,
  pair,
  sendP2p,
}

ConnectionComponentStatus _gateByStartupStep(
  ConnectionComponentStatus raw,
  StartupStep step,
) {
  final detail = step.detail.isEmpty ? raw.detail : step.detail;
  return switch (step.state) {
    StartupStepState.pending || StartupStepState.blocked => raw.copyWith(
      state: ConnectionComponentState.pending,
      detail: detail,
      clearProgress: true,
      clearErrorCode: true,
    ),
    StartupStepState.running =>
      raw.state == ConnectionComponentState.failed
          ? raw
          : raw.copyWith(
              state: ConnectionComponentState.starting,
              detail: detail,
              clearErrorCode: true,
            ),
    StartupStepState.ready => raw,
    StartupStepState.warning => raw.copyWith(
      state: ConnectionComponentState.degraded,
      detail: detail,
    ),
    StartupStepState.error => raw.copyWith(
      state: ConnectionComponentState.failed,
      detail: detail,
    ),
  };
}

ConnectionComponentStatus _torStatus(RuntimeTorStatus transport) {
  final state = switch (transport.phase) {
    TransportPhase.starting ||
    TransportPhase.bootstrapping => ConnectionComponentState.starting,
    TransportPhase.connecting ||
    TransportPhase.connected => ConnectionComponentState.ready,
    TransportPhase.reconnecting ||
    TransportPhase.degraded => ConnectionComponentState.degraded,
    TransportPhase.offline ||
    TransportPhase.error => ConnectionComponentState.failed,
  };
  return ConnectionComponentStatus(
    component: ConnectionComponent.tor,
    state: state,
    detail: transport.detail.isEmpty ? transport.phase.name : transport.detail,
    progress: transport.progress,
    attempt: transport.retryAttempt,
    errorCode: state == ConnectionComponentState.failed
        ? 'TOR_UNAVAILABLE'
        : null,
  );
}

ConnectionComponentStatus _peerStatus({
  required ConnectionComponent component,
  required PeerServerStatus aggregate,
  required StartupStep step,
  required bool allowReadyWhileAggregateStarts,
}) {
  final stepState = _fromStartupState(step.state);
  final state = switch (aggregate) {
    PeerServerStatus.ready => ConnectionComponentState.ready,
    PeerServerStatus.starting =>
      stepState == ConnectionComponentState.failed ||
              stepState == ConnectionComponentState.degraded
          ? stepState
          : allowReadyWhileAggregateStarts &&
                stepState == ConnectionComponentState.ready
          ? ConnectionComponentState.ready
          : ConnectionComponentState.starting,
    PeerServerStatus.offline =>
      component == ConnectionComponent.peerListener &&
              stepState == ConnectionComponentState.ready
          ? ConnectionComponentState.ready
          : ConnectionComponentState.degraded,
    PeerServerStatus.error => ConnectionComponentState.failed,
  };
  return ConnectionComponentStatus(
    component: component,
    state: state,
    detail: step.detail.isEmpty ? component.name : step.detail,
    errorCode: state == ConnectionComponentState.failed
        ? component == ConnectionComponent.peerListener
              ? 'PEER_LISTENER_FAILED'
              : 'ONION_SERVICE_FAILED'
        : null,
  );
}

StartupStep _step(List<StartupStep> steps, StartupStepKind kind) {
  for (final step in steps) {
    if (step.kind == kind) return step;
  }
  return StartupStep(kind: kind);
}

ConnectionComponentState _fromStartupState(StartupStepState state) =>
    switch (state) {
      StartupStepState.pending ||
      StartupStepState.blocked => ConnectionComponentState.pending,
      StartupStepState.running => ConnectionComponentState.starting,
      StartupStepState.ready => ConnectionComponentState.ready,
      StartupStepState.warning => ConnectionComponentState.degraded,
      StartupStepState.error => ConnectionComponentState.failed,
    };
StartupStepState _toStartupState(ConnectionComponentState state) =>
    switch (state) {
      ConnectionComponentState.pending => StartupStepState.pending,
      ConnectionComponentState.starting => StartupStepState.running,
      ConnectionComponentState.ready => StartupStepState.ready,
      ConnectionComponentState.degraded => StartupStepState.warning,
      ConnectionComponentState.failed => StartupStepState.error,
    };
