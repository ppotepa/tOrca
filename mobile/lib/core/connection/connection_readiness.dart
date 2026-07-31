import '../models/domain.dart';
import 'connection_component.dart';
import 'sequential_connection_sequence.dart';

class ConnectionReadiness {
  const ConnectionReadiness({
    required this.engine,
    required this.localData,
    required this.tor,
    required this.relay,
    required this.peerListener,
    required this.onionService,
  });

  factory ConnectionReadiness.fromRuntime({
    required RuntimeTorStatus transport,
    required PeerServerStatus peerServerStatus,
    required List<StartupStep> startupSteps,
    required bool localDataReady,
  }) {
    final engineStep = _step(startupSteps, StartupStepKind.engine);
    final peerListenerStep = _step(
      startupSteps,
      StartupStepKind.peerListener,
    );
    final onionStep = _step(startupSteps, StartupStepKind.onionService);

    // Local data cannot be available before the engine has opened its state.
    // Treat a successful identity read as authoritative even if the earlier
    // runtime-ready event arrived before Flutter attached to the event stream.
    final engineState = localDataReady
        ? ConnectionComponentState.ready
        : _fromStartupState(engineStep.state);
    final localDataState = engineState == ConnectionComponentState.failed
        ? ConnectionComponentState.failed
        : localDataReady
        ? ConnectionComponentState.ready
        : engineState == ConnectionComponentState.pending
        ? ConnectionComponentState.pending
        : ConnectionComponentState.starting;

    final raw = <ConnectionComponentStatus>[
      ConnectionComponentStatus(
        component: ConnectionComponent.engine,
        state: engineState,
        detail: engineStep.detail.isEmpty
            ? ConnectionComponent.engine.description
            : engineStep.detail,
      ),
      ConnectionComponentStatus(
        component: ConnectionComponent.localData,
        state: localDataState,
        detail: localDataReady
            ? 'Tożsamość i zaszyfrowane dane lokalne są gotowe'
            : engineState == ConnectionComponentState.failed
            ? engineStep.detail
            : 'Odczytywanie tożsamości, profilu i lokalnego snapshotu',
      ),
      _torStatus(transport),
      _relayStatus(transport),
      _peerStatus(
        component: ConnectionComponent.peerListener,
        aggregate: peerServerStatus,
        step: peerListenerStep,
        allowReadyWhileAggregateStarts: true,
      ),
      _peerStatus(
        component: ConnectionComponent.onionService,
        aggregate: peerServerStatus,
        step: onionStep,
        allowReadyWhileAggregateStarts: false,
      ),
    ];
    final sequential = sequentialConnectionStatuses(raw);

    return ConnectionReadiness(
      engine: sequential[0],
      localData: sequential[1],
      tor: sequential[2],
      relay: sequential[3],
      peerListener: sequential[4],
      onionService: sequential[5],
    );
  }

  final ConnectionComponentStatus engine;
  final ConnectionComponentStatus localData;
  final ConnectionComponentStatus tor;
  final ConnectionComponentStatus relay;
  final ConnectionComponentStatus peerListener;
  final ConnectionComponentStatus onionService;

  List<ConnectionComponentStatus> get components => [
    engine,
    localData,
    tor,
    relay,
    peerListener,
    onionService,
  ];

  bool get localCoreReady => engine.ready && localData.ready;

  bool get onboardingReady =>
      localCoreReady &&
      tor.ready &&
      relay.ready &&
      peerListener.ready &&
      onionService.ready;

  bool get communicationReady => onboardingReady;

  bool get busy => !communicationReady && components.any((item) => item.busy);

  bool get degraded => components.any(
    (item) => item.state == ConnectionComponentState.degraded,
  );

  bool get failed => components.any(
    (item) => item.state == ConnectionComponentState.failed,
  );

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
      state: _toStartupState(_leastReady(engine.state, localData.state)),
      detail: localData.ready ? engine.detail : localData.detail,
    ),
    StartupStep(
      kind: StartupStepKind.tor,
      state: _toStartupState(tor.state),
      detail: tor.detail,
    ),
    StartupStep(
      kind: StartupStepKind.relay,
      state: _toStartupState(relay.state),
      detail: relay.detail,
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
    final firstBlocking = components.firstWhere(
      (item) => !item.ready,
      orElse: () => onionService,
    );
    if (firstBlocking.state == ConnectionComponentState.failed) {
      return '${firstBlocking.component.title}: ${firstBlocking.detail}';
    }
    if (firstBlocking.state == ConnectionComponentState.degraded) {
      return '${firstBlocking.component.title} działa w trybie ograniczonym';
    }
    return 'Oczekiwanie: ${firstBlocking.component.title.toLowerCase()}';
  }
}

ConnectionComponentStatus _torStatus(RuntimeTorStatus transport) {
  final state = switch (transport.phase) {
    TransportPhase.starting || TransportPhase.bootstrapping =>
      ConnectionComponentState.starting,
    TransportPhase.connecting || TransportPhase.connected =>
      ConnectionComponentState.ready,
    TransportPhase.reconnecting || TransportPhase.degraded =>
      ConnectionComponentState.degraded,
    TransportPhase.offline || TransportPhase.error =>
      ConnectionComponentState.failed,
  };
  return ConnectionComponentStatus(
    component: ConnectionComponent.tor,
    state: state,
    detail: transport.detail.isEmpty ? transport.label : transport.detail,
    progress: transport.progress,
    attempt: transport.retryAttempt,
    errorCode: state == ConnectionComponentState.failed
        ? 'TOR_UNAVAILABLE'
        : null,
  );
}

ConnectionComponentStatus _relayStatus(RuntimeTorStatus transport) {
  final state = switch (transport.phase) {
    TransportPhase.starting || TransportPhase.bootstrapping =>
      ConnectionComponentState.pending,
    TransportPhase.connecting || TransportPhase.reconnecting =>
      ConnectionComponentState.starting,
    TransportPhase.connected => ConnectionComponentState.ready,
    TransportPhase.degraded => ConnectionComponentState.degraded,
    TransportPhase.offline || TransportPhase.error =>
      ConnectionComponentState.failed,
  };
  return ConnectionComponentStatus(
    component: ConnectionComponent.relay,
    state: state,
    detail: transport.detail.isEmpty ? transport.label : transport.detail,
    attempt: transport.retryAttempt,
    errorCode: state == ConnectionComponentState.failed
        ? 'RELAY_UNAVAILABLE'
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
    detail: step.detail.isEmpty ? component.description : step.detail,
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
      StartupStepState.pending || StartupStepState.blocked =>
        ConnectionComponentState.pending,
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

ConnectionComponentState _leastReady(
  ConnectionComponentState first,
  ConnectionComponentState second,
) {
  const order = {
    ConnectionComponentState.ready: 4,
    ConnectionComponentState.degraded: 3,
    ConnectionComponentState.starting: 2,
    ConnectionComponentState.pending: 1,
    ConnectionComponentState.failed: 0,
  };
  return order[first]! <= order[second]! ? first : second;
}
