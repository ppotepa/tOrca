import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/connection/connection_component.dart';
import 'package:torchat_mobile/core/connection/connection_readiness.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_mobile/core/startup/sequential_startup_orchestrator.dart';

void main() {
  test(
    'connected transport exposes local and peer readiness independently',
    () {
      final startup = SequentialStartupOrchestrator()..begin();
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          detail: 'relay already connected',
        ),
        peerServerStatus: PeerServerStatus.ready,
        startupSteps: startup.stepsFor(SequentialStartupPhase.complete),
        localDataReady: true,
      );

      expect(readiness.engine.state, ConnectionComponentState.ready);
      expect(readiness.localData.state, ConnectionComponentState.ready);
      expect(readiness.tor.state, ConnectionComponentState.ready);
      expect(readiness.peerListener.state, ConnectionComponentState.ready);
      expect(readiness.onionService.state, ConnectionComponentState.ready);
    },
  );

  test('early endpoint readiness is released only in its own phases', () {
    final startup = SequentialStartupOrchestrator()..begin();

    final peerPhase = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.connected),
      peerServerStatus: PeerServerStatus.ready,
      startupSteps: startup.stepsFor(SequentialStartupPhase.peerListener),
      localDataReady: true,
    );
    expect(peerPhase.peerListener.state, ConnectionComponentState.starting);
    expect(peerPhase.onionService.state, ConnectionComponentState.pending);

    final onionPhase = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.connected),
      peerServerStatus: PeerServerStatus.ready,
      startupSteps: startup.stepsFor(SequentialStartupPhase.onionService),
      localDataReady: true,
    );
    expect(onionPhase.peerListener.state, ConnectionComponentState.ready);
    expect(onionPhase.onionService.state, ConnectionComponentState.starting);
  });

  test('local shell is ready independently of communication phase', () {
    final startup = SequentialStartupOrchestrator()..begin();

    final finalizing = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.connected),
      peerServerStatus: PeerServerStatus.ready,
      startupSteps: startup.stepsFor(SequentialStartupPhase.communication),
      localDataReady: true,
    );
    expect(finalizing.localCoreReady, isTrue);
    expect(finalizing.communicationReady, isTrue);

    final complete = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.connected),
      peerServerStatus: PeerServerStatus.ready,
      startupSteps: startup.stepsFor(SequentialStartupPhase.complete),
      localDataReady: true,
    );
    expect(complete.communicationReady, isTrue);
    expect(complete.startupSteps.last.state, StartupStepState.ready);
  });
}
