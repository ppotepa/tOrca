import 'package:flutter/material.dart';

import '../../core/connection/connection_readiness.dart';
import '../../core/connection/connection_component.dart';
import '../../core/models/domain.dart';

enum StatusProbeState { idle, starting, ready, degraded, error, offline }

class StatusProbeSnapshot {
  const StatusProbeSnapshot({
    required this.id,
    required this.label,
    required this.detail,
    required this.icon,
    required this.state,
    this.critical = false,
    this.latencyMs,
    this.progress,
    this.retryAttempt = 0,
    this.retryInMs,
    this.endpoint,
  });

  final String id;
  final String label;
  final String detail;
  final IconData icon;
  final StatusProbeState state;
  final bool critical;
  final int? latencyMs;
  final int? progress;
  final int retryAttempt;
  final int? retryInMs;
  final String? endpoint;
}

class TransportDiagnosticsSnapshot {
  const TransportDiagnosticsSnapshot({
    required this.phase,
    required this.peerStatus,
    this.readiness,
    this.statuses = const {},
    this.latencyMs,
  });

  final TransportPhase phase;
  final PeerServerStatus peerStatus;
  final ConnectionReadiness? readiness;
  final Map<TransportComponent, TransportStatusSnapshot> statuses;
  final int? latencyMs;
}

abstract interface class StatusProbe {
  String get id;
  StatusProbeSnapshot read(TransportDiagnosticsSnapshot source);
}

class EngineStatusProbe implements StatusProbe {
  const EngineStatusProbe();

  @override
  String get id => 'engine';

  @override
  StatusProbeSnapshot read(TransportDiagnosticsSnapshot source) {
    final reported = source.statuses[TransportComponent.engine];
    final status = source.readiness?.engine;
    final state = reported == null
        ? _componentState(status?.state)
        : _fromTransportState(reported.state);
    return StatusProbeSnapshot(
      id: id,
      label: 'Silnik',
      detail: reported?.detail ?? status?.detail ?? 'gotowy',
      icon: Icons.settings_rounded,
      state: state,
      critical: true,
      progress: reported?.progress,
      retryAttempt: reported?.retryAttempt ?? 0,
    );
  }
}

class RelayStatusProbe implements StatusProbe {
  const RelayStatusProbe();

  @override
  String get id => 'relay';

  @override
  StatusProbeSnapshot read(TransportDiagnosticsSnapshot source) {
    final reported = source.statuses[TransportComponent.relay];
    return StatusProbeSnapshot(
      id: id,
      label: 'Tor relay',
      detail:
          reported?.detail ??
          (source.latencyMs == null
              ? source.phase.name
              : '${source.latencyMs} ms'),
      icon: Icons.auto_awesome_rounded,
      state: reported == null
          ? _fromPhase(source.phase)
          : _fromTransportState(reported.state),
      latencyMs: reported?.latencyMs ?? source.latencyMs,
      progress: reported?.progress,
      retryAttempt: reported?.retryAttempt ?? 0,
      retryInMs: reported?.retryInMs,
      endpoint: reported?.endpoint,
    );
  }
}

class PeerStatusProbe implements StatusProbe {
  const PeerStatusProbe();

  @override
  String get id => 'peer';

  @override
  StatusProbeSnapshot read(TransportDiagnosticsSnapshot source) {
    final reported = source.statuses[TransportComponent.peer];
    return StatusProbeSnapshot(
      id: id,
      label: 'Tor P2P',
      detail: reported?.detail ?? _peerDetail(source.peerStatus),
      icon: Icons.handshake_rounded,
      state: reported == null
          ? _fromPeer(source.peerStatus)
          : _fromTransportState(reported.state),
      progress: reported?.progress,
      retryAttempt: reported?.retryAttempt ?? 0,
      retryInMs: reported?.retryInMs,
      endpoint: reported?.endpoint,
    );
  }
}

class StatusProbeRegistry {
  const StatusProbeRegistry({this.probes = _defaultProbes});

  static const _defaultProbes = <StatusProbe>[
    EngineStatusProbe(),
    RelayStatusProbe(),
    PeerStatusProbe(),
  ];

  static const standard = StatusProbeRegistry();

  final List<StatusProbe> probes;

  List<StatusProbeSnapshot> read(TransportDiagnosticsSnapshot source) =>
      probes.map((probe) => probe.read(source)).toList(growable: false);
}

StatusProbeState _componentState(ConnectionComponentState? state) =>
    switch (state) {
      ConnectionComponentState.ready => StatusProbeState.ready,
      ConnectionComponentState.starting ||
      ConnectionComponentState.pending => StatusProbeState.starting,
      ConnectionComponentState.degraded => StatusProbeState.degraded,
      ConnectionComponentState.failed => StatusProbeState.error,
      null => StatusProbeState.starting,
    };

StatusProbeState _fromPhase(TransportPhase phase) => switch (phase) {
  TransportPhase.connected => StatusProbeState.ready,
  TransportPhase.degraded => StatusProbeState.degraded,
  TransportPhase.offline => StatusProbeState.offline,
  TransportPhase.error => StatusProbeState.error,
  _ => StatusProbeState.starting,
};

StatusProbeState _fromPeer(PeerServerStatus status) => switch (status) {
  PeerServerStatus.ready => StatusProbeState.ready,
  PeerServerStatus.error => StatusProbeState.error,
  PeerServerStatus.offline => StatusProbeState.offline,
  PeerServerStatus.starting => StatusProbeState.starting,
};

StatusProbeState _fromTransportState(TransportProbeState state) =>
    switch (state) {
      TransportProbeState.idle => StatusProbeState.idle,
      TransportProbeState.starting => StatusProbeState.starting,
      TransportProbeState.ready => StatusProbeState.ready,
      TransportProbeState.degraded => StatusProbeState.degraded,
      TransportProbeState.error => StatusProbeState.error,
      TransportProbeState.offline => StatusProbeState.offline,
    };

String _peerDetail(PeerServerStatus status) => switch (status) {
  PeerServerStatus.ready => 'aktywny',
  PeerServerStatus.starting => 'uruchamianie',
  PeerServerStatus.offline => 'offline',
  PeerServerStatus.error => 'błąd',
};
