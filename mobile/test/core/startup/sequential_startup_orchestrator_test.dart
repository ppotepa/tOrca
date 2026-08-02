import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/startup/sequential_startup_orchestrator.dart';

void main() {
  test('facts observed early satisfy later sequential waits', () async {
    final startup = SequentialStartupOrchestrator();
    final generation = startup.begin();

    startup.observeRuntimeReady();
    startup.observeTransport(
      const RuntimeTorStatus(phase: TransportPhase.connected),
    );
    startup.observeRelayReady(true);
    startup.observePeerListenerReady();
    startup.observePeerEndpoint(true);

    await startup.waitForTor(generation);
    await startup.waitForRelay(generation);
    await startup.waitForPeerListener(generation);
    await startup.waitForOnionService(generation);

    expect(startup.runtimeReady, isTrue);
    expect(startup.peerListenerReady, isTrue);
    expect(startup.onionServiceReady, isTrue);
  });

  test('new generation cancels a waiter from the previous warmup', () async {
    final startup = SequentialStartupOrchestrator();
    final firstGeneration = startup.begin();
    final oldWait = startup.waitForRelay(
      firstGeneration,
      timeout: const Duration(seconds: 2),
    );

    startup.begin();

    await expectLater(oldWait, throwsA(isA<StartupGenerationChanged>()));
  });

  test('phase projection exposes exactly one current startup step', () {
    final startup = SequentialStartupOrchestrator();
    startup.begin();

    final steps = startup.stepsFor(SequentialStartupPhase.relay);
    final running = steps
        .where((step) => step.state == StartupStepState.running)
        .toList();

    expect(running, hasLength(1));
    expect(running.single.kind, StartupStepKind.relay);
    expect(
      steps.firstWhere((step) => step.kind == StartupStepKind.engine).state,
      StartupStepState.ready,
    );
    expect(
      steps.firstWhere((step) => step.kind == StartupStepKind.tor).state,
      StartupStepState.ready,
    );
    expect(
      steps
          .firstWhere((step) => step.kind == StartupStepKind.peerListener)
          .state,
      StartupStepState.ready,
    );
    expect(
      steps
          .firstWhere((step) => step.kind == StartupStepKind.onionService)
          .state,
      StartupStepState.ready,
    );
  });

  test('failed phase blocks all later phases', () {
    final startup = SequentialStartupOrchestrator();
    startup.begin();

    final steps = startup.stepsFor(
      SequentialStartupPhase.tor,
      error: StateError('tor failed'),
    );
    final torIndex = steps.indexWhere(
      (step) => step.kind == StartupStepKind.tor,
    );

    expect(steps[torIndex].state, StartupStepState.error);
    for (var index = torIndex + 1; index < steps.length; index += 1) {
      expect(steps[index].state, StartupStepState.blocked);
    }
  });
}
