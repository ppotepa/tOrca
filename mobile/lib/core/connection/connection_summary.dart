import '../models/domain.dart';
import 'connection_component.dart';
import 'connection_readiness.dart';

class ConnectionSummary {
  const ConnectionSummary({
    required this.status,
    required this.detail,
    required this.phase,
    required this.peerServerStatus,
    this.latencyMs,
  });

  factory ConnectionSummary.fromReadiness({
    required ConnectionReadiness readiness,
    required RuntimeTorStatus transport,
  }) {
    if (readiness.communicationReady) {
      return ConnectionSummary(
        status: 'Połączono przez Tor · P2P gotowe',
        detail: 'Relay i onion tego urządzenia są gotowe.',
        phase: TransportPhase.connected,
        peerServerStatus: PeerServerStatus.ready,
        latencyMs: transport.latencyMs,
      );
    }

    if (readiness.relay.ready && !readiness.onionService.ready) {
      return ConnectionSummary(
        status: 'Relay połączony · P2P się rozgrzewa',
        detail: readiness.onionService.detail,
        phase: TransportPhase.degraded,
        peerServerStatus: readiness.peerServerStatus,
        latencyMs: transport.latencyMs,
      );
    }

    if (readiness.localCoreReady &&
        readiness.relay.state == ConnectionComponentState.failed) {
      return ConnectionSummary(
        status: 'Offline · dane lokalne dostępne',
        detail: readiness.relay.detail.isEmpty
            ? 'Relay jest niedostępny. Wiadomości pozostają w kolejce.'
            : readiness.relay.detail,
        phase: TransportPhase.offline,
        peerServerStatus: readiness.peerServerStatus,
        latencyMs: transport.latencyMs,
      );
    }

    if (readiness.failed) {
      final failed = readiness.components.firstWhere(
        (item) => item.state == ConnectionComponentState.failed,
      );
      return ConnectionSummary(
        status: 'Attention required: ${failed.component.name}',
        detail: failed.detail,
        phase: TransportPhase.error,
        peerServerStatus: readiness.peerServerStatus,
        latencyMs: transport.latencyMs,
      );
    }

    final active = readiness.components.firstWhere(
      (item) => !item.ready,
      orElse: () => readiness.relay,
    );
    return ConnectionSummary(
      status: 'Warming up: ${active.component.name}',
      detail: active.detail,
      phase: transport.phase.isError
          ? TransportPhase.connecting
          : transport.phase,
      peerServerStatus: readiness.peerServerStatus,
      latencyMs: transport.latencyMs,
    );
  }

  final String status;
  final String detail;
  final TransportPhase phase;
  final PeerServerStatus peerServerStatus;
  final int? latencyMs;
}
