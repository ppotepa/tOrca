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

      expect(readiness.relay.ready, isFalse);
      expect(readiness.peerListener.ready, isTrue);
      expect(readiness.onionService.state, ConnectionComponentState.starting);
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
    test('returning user can open local shell while Tor is offline', () {
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

    test('new user can open onboarding once local data is ready', () {
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
        AppLaunchPhase.onboarding,
      );
      expect(
        resolveLaunchPhase(profile: const RuntimeProfile(), connection: ready),
        AppLaunchPhase.onboarding,
      );
    });

    test('operation gates separate local reads from network capabilities', () {
      final localOnly = ConnectionReadiness.fromRuntime(
        transport: const RuntimeTorStatus(phase: TransportPhase.offline),
        peerServerStatus: PeerServerStatus.offline,
        startupSteps: _readyLegacySteps(),
        localDataReady: true,
      );

      expect(localOnly.canPerform(ConnectionOperation.readLocalData), isTrue);
      expect(localOnly.canPerform(ConnectionOperation.diagnose), isTrue);
      expect(localOnly.canPerform(ConnectionOperation.pair), isFalse);
      expect(localOnly.canPerform(ConnectionOperation.sendP2p), isFalse);
      expect(
        localOnly.canPerform(ConnectionOperation.sendRelayFallback),
        isFalse,
      );
    });

    test('P2P-only keeps local reads and direct send available when relay is down', () {
      final readiness = _capabilityReadiness(
        relay: ConnectionComponentState.degraded,
        peer: ConnectionComponentState.ready,
      );

      expect(readiness.canPerform(ConnectionOperation.readLocalData), isTrue);
      expect(readiness.canPerform(ConnectionOperation.sendP2p), isTrue);
      expect(readiness.canPerform(ConnectionOperation.sendRelayFallback), isFalse);
      expect(readiness.canPerform(ConnectionOperation.pair), isFalse);
    });

    test('relay-only degraded mode keeps fallback send but not direct P2P', () {
      final readiness = _capabilityReadiness(
        relay: ConnectionComponentState.ready,
        peer: ConnectionComponentState.degraded,
      );

      expect(readiness.canPerform(ConnectionOperation.readLocalData), isTrue);
      expect(readiness.canPerform(ConnectionOperation.sendP2p), isFalse);
      expect(readiness.canPerform(ConnectionOperation.sendRelayFallback), isTrue);
      expect(readiness.canPerform(ConnectionOperation.pair), isTrue);
    });

    test('full offline mode leaves only local reads and diagnostics available', () {
      final readiness = _capabilityReadiness(
        relay: ConnectionComponentState.degraded,
        peer: ConnectionComponentState.degraded,
      );

      expect(readiness.canPerform(ConnectionOperation.readLocalData), isTrue);
      expect(readiness.canPerform(ConnectionOperation.diagnose), isTrue);
      expect(readiness.canPerform(ConnectionOperation.pair), isFalse);
      expect(readiness.canPerform(ConnectionOperation.sendP2p), isFalse);
      expect(readiness.canPerform(ConnectionOperation.sendRelayFallback), isFalse);
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

ConnectionReadiness _capabilityReadiness({
  required ConnectionComponentState relay,
  required ConnectionComponentState peer,
}) => ConnectionReadiness(
  engine: const ConnectionComponentStatus(
    component: ConnectionComponent.engine,
    state: ConnectionComponentState.ready,
  ),
  localData: const ConnectionComponentStatus(
    component: ConnectionComponent.localData,
    state: ConnectionComponentState.ready,
  ),
  tor: const ConnectionComponentStatus(
    component: ConnectionComponent.tor,
    state: ConnectionComponentState.ready,
  ),
  relay: ConnectionComponentStatus(
    component: ConnectionComponent.relay,
    state: relay,
  ),
  peerListener: ConnectionComponentStatus(
    component: ConnectionComponent.peerListener,
    state: peer,
  ),
  onionService: const ConnectionComponentStatus(
    component: ConnectionComponent.onionService,
    state: ConnectionComponentState.degraded,
  ),
  communicationCommitted: false,
  communicationDetail: 'degraded test',
);
