import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/connection/connection_gate.dart';
import 'package:torchat_mobile/core/connection/connection_readiness.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

void main() {
  test('local data opens the shell while network is still unavailable', () {
    final readiness = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.offline),
      peerServerStatus: PeerServerStatus.offline,
      startupSteps: _steps(),
      localDataReady: true,
    );

    expect(readiness.localCoreReady, isTrue);
    expect(readiness.onboardingReady, isTrue);
    expect(readiness.communicationReady, isTrue);
    expect(
      resolveLaunchPhase(
        profile: const RuntimeProfile(nickname: 'Alice'),
        connection: readiness,
      ),
      AppLaunchPhase.running,
    );
  });

  test('network operations remain gated by direct peer readiness', () {
    final readiness = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.offline),
      peerServerStatus: PeerServerStatus.offline,
      startupSteps: _steps(),
      localDataReady: true,
    );

    expect(readiness.canPerform(ConnectionOperation.readLocalData), isTrue);
    expect(readiness.canPerform(ConnectionOperation.diagnose), isTrue);
    expect(readiness.canPerform(ConnectionOperation.pair), isFalse);
    expect(readiness.canPerform(ConnectionOperation.sendP2p), isFalse);
  });

  test('engine readiness does not imply local data readiness', () {
    final readiness = ConnectionReadiness.fromRuntime(
      transport: const RuntimeTorStatus(phase: TransportPhase.connected),
      peerServerStatus: PeerServerStatus.ready,
      startupSteps: _steps(),
      localDataReady: false,
    );

    expect(readiness.engine.ready, isTrue);
    expect(readiness.localCoreReady, isFalse);
    expect(readiness.onboardingReady, isFalse);
  });
}

List<StartupStep> _steps() => [
  for (final kind in StartupStepKind.values)
    StartupStep(kind: kind, state: StartupStepState.ready),
];
