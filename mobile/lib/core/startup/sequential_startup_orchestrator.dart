import 'dart:async';

import '../models/domain.dart';

enum SequentialStartupPhase {
  engine,
  localData,
  tor,
  relay,
  peerListener,
  onionService,
  communication,
  complete,
}

class StartupGenerationChanged implements Exception {
  const StartupGenerationChanged(this.expected, this.actual);

  final int expected;
  final int actual;

  @override
  String toString() =>
      'Startup generation changed: expected=$expected actual=$actual';
}

class SequentialStartupOrchestrator {
  int _generation = 0;
  int _revision = 0;
  RuntimeTorStatus _transport = const RuntimeTorStatus();
  bool _runtimeReady = false;
  bool _relayReady = false;
  bool _peerListenerReady = false;
  bool _onionServiceReady = false;
  Object? _failure;
  final List<Completer<void>> _waiters = [];

  int get generation => _generation;
  RuntimeTorStatus get transport => _transport;
  bool get runtimeReady => _runtimeReady;
  bool get peerListenerReady => _peerListenerReady;
  bool get onionServiceReady => _onionServiceReady;

  int begin({
    RuntimeTorStatus transport = const RuntimeTorStatus(),
    bool runtimeReady = false,
  }) {
    _generation += 1;
    _revision += 1;
    _transport = transport;
    _runtimeReady = runtimeReady;
    _relayReady = false;
    _peerListenerReady = false;
    _onionServiceReady = false;
    _failure = null;
    _notifyWaiters();
    return _generation;
  }

  void observeRuntimeReady() {
    _runtimeReady = true;
    // Runtime readiness only proves that the shared engine is alive. The local
    // P2P listener has its own lifecycle and must publish a separate fact;
    // conflating the two allowed warmup to continue with no peer server.
    _changed();
  }

  void observePeerListenerReady() {
    _peerListenerReady = true;
    _changed();
  }

  void observeTransport(RuntimeTorStatus transport) {
    _transport = transport;
    _changed();
  }

  /// Relay readiness is a separate component from Tor SOCKS readiness. Tor
  /// can be fully bootstrapped while the authenticated relay WebSocket is
  /// still connecting or retrying.
  void observeRelayReady(bool ready) {
    _relayReady = ready;
    _changed();
  }

  void observePeerEndpoint(bool available) {
    if (available) {
      _onionServiceReady = true;
    } else {
      _onionServiceReady = false;
    }
    _changed();
  }

  void fail(Object error) {
    _failure = error;
    _changed();
  }

  void cancel() {
    _generation += 1;
    _revision += 1;
    _failure = const StartupCancelled();
    _notifyWaiters();
  }

  Future<void> waitForTor(
    int generation, {
    Duration timeout = const Duration(minutes: 2),
  }) => _waitFor(
    generation,
    timeout,
    'Tor did not become ready',
    () => _transport.phase == TransportPhase.connected,
  );

  Future<void> waitForRelay(
    int generation, {
    // A cold onion circuit can legitimately require several guarded retries.
    // Keep one UI deadline wider than the engine's complete retry ladder; the
    // engine remains the owner of individual request timeouts and backoff.
    Duration timeout = const Duration(minutes: 5),
  }) => _waitFor(
    generation,
    timeout,
    'Relay did not become ready',
    () => _relayReady,
  );

  Future<void> waitForPeerListener(
    int generation, {
    Duration timeout = const Duration(seconds: 30),
  }) => _waitFor(
    generation,
    timeout,
    'Local peer listener did not become ready',
    () => _peerListenerReady,
  );

  Future<void> waitForOnionService(
    int generation, {
    Duration timeout = const Duration(minutes: 1),
  }) => _waitFor(
    generation,
    timeout,
    'Local onion service did not become ready',
    () => _onionServiceReady,
  );

  Future<void> _waitFor(
    int expectedGeneration,
    Duration timeout,
    String timeoutMessage,
    bool Function() predicate,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var observedRevision = -1;
    while (true) {
      _ensureGeneration(expectedGeneration);
      final failure = _failure;
      if (failure != null) throw failure;
      if (predicate()) return;

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(timeoutMessage, timeout);
      }

      if (observedRevision == _revision) {
        final completer = Completer<void>();
        _waiters.add(completer);
        try {
          await completer.future.timeout(remaining);
        } on TimeoutException {
          throw TimeoutException(timeoutMessage, timeout);
        } finally {
          _waiters.remove(completer);
        }
      }
      observedRevision = _revision;
    }
  }

  void _ensureGeneration(int expected) {
    if (_generation != expected) {
      throw StartupGenerationChanged(expected, _generation);
    }
  }

  void _changed() {
    _revision += 1;
    _notifyWaiters();
  }

  void _notifyWaiters() {
    final waiters = List<Completer<void>>.from(_waiters);
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  List<StartupStep> stepsFor(
    SequentialStartupPhase phase, {
    String? detail,
    Object? error,
  }) {
    final steps = initialStartupSteps();
    if (phase == SequentialStartupPhase.complete) {
      return [
        for (final step in steps)
          step.copyWith(
            state: StartupStepState.ready,
            detail: _readyDetail(step.kind),
          ),
      ];
    }

    final currentKind = _kindFor(phase);
    final currentIndex = currentKind == null
        ? -1
        : steps.indexWhere((step) => step.kind == currentKind);
    final completedKinds = _completedKinds(phase);

    return [
      for (var index = 0; index < steps.length; index += 1)
        if (completedKinds.contains(steps[index].kind))
          steps[index].copyWith(
            state: StartupStepState.ready,
            detail: _readyDetail(steps[index].kind),
          )
        else if (index == currentIndex)
          steps[index].copyWith(
            state: error == null
                ? StartupStepState.running
                : StartupStepState.error,
            detail: error?.toString() ?? detail ?? _runningDetail(phase),
          )
        else if (error != null && currentIndex >= 0 && index > currentIndex)
          steps[index].copyWith(
            state: StartupStepState.blocked,
            detail: 'Zablokowano przez wcześniejszy błąd',
          )
        else
          steps[index],
    ];
  }

  Set<StartupStepKind> _completedKinds(SequentialStartupPhase phase) =>
      switch (phase) {
        SequentialStartupPhase.engine => const {},
        SequentialStartupPhase.localData => const {StartupStepKind.engine},
        SequentialStartupPhase.tor => const {
          StartupStepKind.engine,
          StartupStepKind.localData,
        },
        SequentialStartupPhase.peerListener => const {
          StartupStepKind.engine,
          StartupStepKind.localData,
          StartupStepKind.tor,
        },
        SequentialStartupPhase.onionService => const {
          StartupStepKind.engine,
          StartupStepKind.localData,
          StartupStepKind.tor,
          StartupStepKind.peerListener,
        },
        SequentialStartupPhase.relay => const {
          StartupStepKind.engine,
          StartupStepKind.localData,
          StartupStepKind.tor,
          StartupStepKind.peerListener,
          StartupStepKind.onionService,
        },
        SequentialStartupPhase.communication => const {
          StartupStepKind.engine,
          StartupStepKind.localData,
          StartupStepKind.tor,
          StartupStepKind.peerListener,
          StartupStepKind.onionService,
          StartupStepKind.relay,
        },
        SequentialStartupPhase.complete => StartupStepKind.values.toSet(),
      };

  StartupStepKind? _kindFor(SequentialStartupPhase phase) => switch (phase) {
    SequentialStartupPhase.engine => StartupStepKind.engine,
    SequentialStartupPhase.localData => StartupStepKind.localData,
    SequentialStartupPhase.tor => StartupStepKind.tor,
    SequentialStartupPhase.peerListener => StartupStepKind.peerListener,
    SequentialStartupPhase.onionService => StartupStepKind.onionService,
    SequentialStartupPhase.relay => StartupStepKind.relay,
    SequentialStartupPhase.communication => StartupStepKind.communication,
    SequentialStartupPhase.complete => null,
  };

  String _runningDetail(SequentialStartupPhase phase) => switch (phase) {
    SequentialStartupPhase.engine => 'Uruchamianie wspólnego engine',
    SequentialStartupPhase.localData =>
      'Odczytywanie zaszyfrowanych danych lokalnych',
    SequentialStartupPhase.tor => 'Oczekiwanie na gotowość sieci Tor',
    SequentialStartupPhase.relay => 'Łączenie z relayem onion',
    SequentialStartupPhase.peerListener =>
      'Uruchamianie lokalnego listenera P2P',
    SequentialStartupPhase.onionService => 'Publikowanie lokalnej usługi onion',
    SequentialStartupPhase.communication =>
      'Finalizowanie gotowości komunikacji',
    SequentialStartupPhase.complete => 'TorChat jest gotowy',
  };

  String _readyDetail(StartupStepKind kind) => switch (kind) {
    StartupStepKind.engine => 'Wspólny engine jest gotowy',
    StartupStepKind.localData => 'Tożsamość i dane lokalne są gotowe',
    StartupStepKind.tor => 'Sieć Tor jest gotowa',
    StartupStepKind.relay => 'Relay onion jest połączony',
    StartupStepKind.peerListener => 'Lokalny listener P2P działa',
    StartupStepKind.onionService => 'Lokalny adres onion jest opublikowany',
    StartupStepKind.communication => 'TorChat jest gotowy do komunikacji',
  };
}

class StartupCancelled implements Exception {
  const StartupCancelled();

  @override
  String toString() => 'Startup cancelled';
}
