import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/connection/connection_component.dart';
import 'package:torchat_mobile/core/connection/connection_gate.dart';
import 'package:torchat_mobile/core/connection/connection_readiness.dart';
import 'package:torchat_mobile/core/models/domain.dart';

void main() {
  group('ConnectionReadiness', () {
    test('does not trust a sticky onion ready step during runtime warmup', () {
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.starting,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      expect(readiness.relay.ready, isTrue);
      expect(readiness.peerListener.ready, isTrue);
      expect(
        readiness.onionService.state,
        ConnectionComponentState.starting,
      );
      expect(readiness.onboardingReady, isFalse);
      expect(readiness.communicationReady, isFalse);
    });

    test('opens onboarding only when relay and local onion are ready', () {
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.ready,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      expect(readiness.onboardingReady, isTrue);
      expect(readiness.communicationReady, isTrue);
      expect(readiness.startupSteps.last.state, StartupStepState.ready);
    });

    test('contact sessions are not part of onboarding readiness', () {
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.ready,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      // Readiness has no contact collection or peer-session dependency.
      expect(readiness.onboardingReady, isTrue);
    });

    test('engine ready does not imply local data ready', () {
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.ready,
        startupSteps: _readyLegacySteps(),
        localDataReady: false,
      );

      expect(readiness.engine.ready, isTrue);
      expect(readiness.localData.ready, isFalse);
      expect(readiness.localCoreReady, isFalse);
      expect(readiness.onboardingReady, isFalse);
    });
  });

  group('resolveLaunchPhase', () {
    test('returning user enters local shell while Tor is offline', () {
      final readiness = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.offline,
          label: 'Offline',
        ),
        peerServerStatus: PeerServerStatus.offline,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      expect(readiness.localCoreReady, isTrue);
      expect(
        resolveLaunchPhase(
          profile: const RuntimeProfile(nickname: 'Alice'),
          connection: readiness,
        ),
        AppLaunchPhase.running,
      );
    });

    test('new user remains on warmup until local onion is ready', () {
      final warming = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.starting,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );
      final ready = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(
          phase: TransportPhase.connected,
          label: 'Połączono',
        ),
        peerServerStatus: PeerServerStatus.ready,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      expect(
        resolveLaunchPhase(
          profile: const RuntimeProfile(),
          connection: warming,
        ),
        AppLaunchPhase.warming,
      );
      expect(
        resolveLaunchPhase(
          profile: const RuntimeProfile(),
          connection: ready,
        ),
        AppLaunchPhase.onboarding,
      );
    });
  });
}

List<StartupStep> _readyLegacySteps() => [
  for (final kind in StartupStepKind.values)
    StartupStep(
      kind: kind,
      state: StartupStepState.ready,
      detail: '${kind.name} ready',
    ),
];
