import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import 'package:torchat_flutter_ui/core/runtime/generated/runtime_contract.g.dart';
import '../core/runtime/runtime_repository.dart';
import '../core/startup/sequential_startup_orchestrator.dart';
import '../core/presence/contact_probe_coordinator.dart';
import '../core/presence/contact_presence_store.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_base.dart' as base;

class SequentialAppController extends base.AppController {
  final SequentialStartupOrchestrator _startup =
      SequentialStartupOrchestrator();
  final Map<String, Timer> _typingExpiry = {};
  late ContactPresenceStore contactPresence;
  late final ContactProbeCoordinator _presenceCoordinator =
      ContactProbeCoordinator(contactPresence);

  late ClientRuntime _runtime;
  late RuntimeRepository _repository;
  StreamSubscription<RuntimeEvent>? _events;
  Future<void>? _initializeInFlight;
  Future<void> _refreshTail = Future<void>.value();
  Future<void>? _eventRefreshInFlight;
  final Set<String> _eventMessageRefreshes = <String>{};
  bool _eventRefreshQueued = false;
  bool _eventRefreshNeedsPairing = false;
  bool _refreshAfterWarmup = false;
  bool _warming = false;
  bool _startupComplete = false;
  bool _introPlayed = false;
  SequentialStartupPhase _phase = SequentialStartupPhase.engine;

  @override
  base.AppState build() {
    final initial = super.build();
    _runtime = ref.read(base.clientRuntimeProvider);
    _repository = ref.read(base.runtimeRepositoryProvider);
    contactPresence = ref.read(contactPresenceStoreProvider);
    ref.onDispose(() {
      _startup.cancel();
      _events?.cancel();
      _presenceCoordinator.dispose();
      for (final timer in _typingExpiry.values) {
        timer.cancel();
      }
    });
    return initial;
  }

  @override
  Future<void> initialize() {
    final current = _initializeInFlight;
    if (current != null) return current;

    late final Future<void> run;
    run = _runSequentialWarmup().whenComplete(() {
      if (identical(_initializeInFlight, run)) {
        _initializeInFlight = null;
      }
    });
    _initializeInFlight = run;
    return run;
  }

  void reattachPresence() => _presenceCoordinator.reattach();

  Future<void> _runSequentialWarmup() async {
    _events ??= _repository.events.listen(
      _handleSequentialEvent,
      onError: (Object error, StackTrace stackTrace) {
        _handleEventStreamFailure(error, stackTrace);
      },
      onDone: () {
        if (_warming) {
          _handleEventStreamFailure(
            StateError('Desktop runtime event stream closed during warmup'),
            StackTrace.current,
          );
        }
      },
    );
    final generation = _startup.begin(
      transport: state.transport,
      runtimeReady: state.identity.installationId.isNotEmpty,
    );
    final retainedIdentity =
        _repository.applicationState.current?.identity.installationId ?? '';
    _warming = true;
    _startupComplete = false;
    var localShellReady = false;
    _applyPhase(SequentialStartupPhase.engine);
    state = state.copyWith(
      screen: base.ControllerScreen.boot,
      isLoading: true,
      action: OperationAction.connect,
      error: '',
      peerServerStatus: PeerServerStatus.starting,
    );

    try {
      // Keep engine and local-data readiness as separate, ordered phases.
      await _runtime.connect().timeout(const Duration(seconds: 60));
      _ensureGeneration(generation);
      final readiness = await _runtime.startupReadiness().timeout(
        const Duration(seconds: 15),
      );
      _ensureGeneration(generation);
      if (!readiness.engineReady || !readiness.localDataReady) {
        throw StateError(
          readiness.detail.isEmpty
              ? 'Engine or local data did not become ready'
              : readiness.detail,
        );
      }
      _startup.observeRuntimeReady();
      if (readiness.peerListenerReady) {
        _startup.observePeerListenerReady();
      }
      if (readiness.onionServiceReady) {
        _startup.observePeerEndpoint(true);
      }
      final restoredTransport = RuntimeTorStatus(
        phase: readiness.torReady
            ? TransportPhase.connected
            : TransportPhase.starting,
        label: readiness.torReady ? 'tor_ready' : 'starting',
        detail: readiness.detail,
      );
      _startup.observeTransport(restoredTransport);
      state = state.copyWith(transport: restoredTransport);

      _applyPhase(SequentialStartupPhase.localData);
      final snapshot = await _repository
          .applicationSnapshot(force: true)
          .timeout(const Duration(seconds: 30));
      _ensureGeneration(generation);
      if (retainedIdentity.isNotEmpty &&
          snapshot.identity.installationId.isNotEmpty &&
          retainedIdentity != snapshot.identity.installationId) {
        _repository.invalidatePairingCache(markSnapshotStale: false);
        _repository.invalidateMessages();
      }
      state = state.copyWith(
        peerServerStatus: snapshot.peerEndpointAvailable
            ? PeerServerStatus.ready
            : PeerServerStatus.starting,
        isLoading: false,
        // Local data is the shell gate. Tor, relay, onion and per-contact
        // reachability remain capability/transport states and may recover in
        // the background without hiding history and settings.
        screen: snapshot.profile.nickname.trim().isNotEmpty
            ? base.ControllerScreen.main
            : base.ControllerScreen.nickname,
      );
      localShellReady = true;
      _startupComplete = true;
      _startup.observePeerEndpoint(snapshot.peerEndpointAvailable);

      state = state.copyWith(
        startupSteps: _startup.stepsFor(SequentialStartupPhase.localData),
        peerServerStatus: snapshot.peerEndpointAvailable
            ? PeerServerStatus.ready
            : PeerServerStatus.starting,
        screen: snapshot.profile.nickname.trim().isNotEmpty
            ? base.ControllerScreen.main
            : base.ControllerScreen.nickname,
        isLoading: false,
        action: '',
        error: '',
      );
    } catch (error) {
      if (error is StartupGenerationChanged || error is StartupCancelled) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        action: '',
        error: _message(error),
        problem: problemForError(error),
        startupSteps: _startup.stepsFor(_phase, error: _message(error)),
        screen: localShellReady
            ? (state.profile.nickname.trim().isNotEmpty
                  ? base.ControllerScreen.main
                  : base.ControllerScreen.nickname)
            : base.ControllerScreen.boot,
      );
    } finally {
      if (_startup.generation == generation) {
        _warming = false;
        if (_startupComplete) {
          // Events can arrive while the readiness gate is warming. Preserve
          // the strongest requested refresh so an invite is not hidden until
          // the next app restart.
          final needsPairing = _refreshAfterWarmup || _eventRefreshNeedsPairing;
          _refreshAfterWarmup = false;
          unawaited(
            refreshData(forcePairing: needsPairing, allowAutoTorka: true),
          );
        } else if (_refreshAfterWarmup) {
          _refreshAfterWarmup = false;
          _scheduleEventRefresh();
        }
      }
    }
  }

  void _ensureGeneration(int expected) {
    if (_startup.generation != expected) {
      throw StartupGenerationChanged(expected, _startup.generation);
    }
  }

  void _applyPhase(SequentialStartupPhase phase) {
    _phase = phase;
    state = state.copyWith(startupSteps: _startup.stepsFor(phase), error: '');
  }

  @override
  Future<void> retryTor() async {
    final current = _initializeInFlight;
    if (current != null) {
      _startup.cancel();
      try {
        await current;
      } catch (_) {
        // The cancelled generation is expected to finish exceptionally.
      }
    }
    await initialize();
  }

  @override
  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) {
    if (_warming) {
      _refreshAfterWarmup = true;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _refreshTail = _refreshTail.catchError((Object _) {}).then<void>((_) async {
      try {
        await super.refreshData(
          forcePairing: forcePairing,
          allowAutoTorka: allowAutoTorka,
        );
        _restoreStartupProjection();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _restoreStartupProjection() {
    if (_warming) {
      state = state.copyWith(startupSteps: _startup.stepsFor(_phase));
    } else if (_startupComplete) {
      state = state.copyWith(
        startupSteps: _startup.stepsFor(SequentialStartupPhase.complete),
      );
    }
  }

  void _handleSequentialEvent(RuntimeEvent event) {
    for (final conversation in state.conversations) {
      _presenceCoordinator.bindConversation(
        conversation.id,
        conversation.contactId,
      );
    }
    _presenceCoordinator.accept(event);
    switch (event) {
      case RuntimeReadyEvent():
        _startup.observeRuntimeReady();
      case TorStatusEvent(:final snapshot):
        final becameConnected =
            !state.transport.connected && snapshot.connected;
        _startup.observeTransport(snapshot);
        state = state.copyWith(
          transport: snapshot,
          error: snapshot.phase.isError ? state.error : '',
        );
        if (becameConnected &&
            state.profile.nickname.trim().isEmpty &&
            !_introPlayed) {
          _introPlayed = true;
          unawaited(_playIntro());
        }
      case TransportStatusChangedEvent(:final snapshot):
        state = state.copyWith(
          transportStatuses: {
            ...state.transportStatuses,
            snapshot.component: snapshot,
          },
        );
        if (snapshot.component == TransportComponent.peer &&
            snapshot.state == TransportProbeState.ready) {
          _startup.observePeerListenerReady();
          state = state.copyWith(peerServerStatus: PeerServerStatus.ready);
        }
      case ProfileReadyEvent():
        _repository.invalidateLocalCache();
        state = state.copyWith(error: '');
      case DataChangedEvent(:final type, :final payload):
        if (type == EngineContract.typingChanged) {
          _applyTyping(payload);
        } else if (type == EngineContract.conversationFocusChanged) {
          _applyConversationFocus(payload);
        } else if (type == EngineContract.presenceChanged) {
          final contactId = payload[EngineContract.contactId]?.toString();
          // Presence state is owned by ContactProbeCoordinator.
          if (contactId == null || contactId.isEmpty) break;
        } else {
          if (type == EngineContract.projectionChanged) {
            final incomingRevision =
                (payload[EngineContract.revision] as num?)?.toInt() ?? 0;
            final currentRevision =
                _repository.applicationState.current?.projectionRevision ?? 0;
            // Duplicate/replayed projection notifications are harmless. A
            // newer revision schedules one coalesced authoritative refresh.
            if (incomingRevision > 0 && incomingRevision <= currentRevision) {
              break;
            }
          }
          _repository.invalidateLocalCache();
          if (type == EngineContract.inviteReceived ||
              type == EngineContract.inviteStateChanged) {
            _repository.invalidatePairingCache();
            _eventRefreshNeedsPairing = true;
          }
          final changeKind = type == EngineContract.changed
              ? payload[EngineContract.kind]?.toString() ?? ''
              : type;
          if (type == EngineContract.messageReceived ||
              type == EngineContract.messageStateChanged) {
            // Message events are self-addressing. Never infer a conversation
            // from the currently selected UI route: an event for another
            // contact would otherwise refresh or overwrite the open chat.
            final conversationId = payload[EngineContract.conversationId]
                ?.toString();
            if (conversationId != null && conversationId.isNotEmpty) {
              _repository.invalidateMessages(conversationId);
              _eventMessageRefreshes.add(conversationId);
            } else {
              // A malformed or obsolete event cannot be safely routed. Recover by
              // refreshing the application projection, without assigning it
              // to the active conversation. Do not clear a pending pairing
              // refresh here: unrelated events must never suppress an invite.
            }
          } else if (changeKind.startsWith('messages:')) {
            final conversationId = changeKind.substring('messages:'.length);
            if (conversationId.isNotEmpty) {
              _repository.invalidateMessages(conversationId);
              _eventMessageRefreshes.add(conversationId);
            }
          }
          _scheduleEventRefresh();
        }
      case PeerEndpointChangedEvent(:final contactId, :final status):
        _repository.invalidateLocalCache();
        final identity = state.identity.installationId;
        final local = identity.isNotEmpty && contactId == identity;
        if (local) {
          final available = status == PeerEndpointStatus.verified;
          _startup.observePeerEndpoint(available);
          state = state.copyWith(
            peerServerStatus: available
                ? PeerServerStatus.ready
                : PeerServerStatus.starting,
          );
        }
        _scheduleEventRefresh();
      case PeerConnectionChangedEvent():
        _repository.invalidateLocalCache();
        _scheduleEventRefresh();
      case ContactCapabilityChangedEvent():
        _repository.invalidateLocalCache();
        _scheduleEventRefresh();
      case RuntimeErrorEvent(:final message):
        if (_isFatalStartupError(message)) {
          _startup.fail(StateError(message));
        }
        state = state.copyWith(error: message);
      case RuntimeLogEvent():
      // Diagnostic text is never a readiness protocol. Typed snapshots and
      // events above are the only inputs to the startup gate.
      case NotificationRequestedEvent():
        unawaited(_notificationBeep());
    }
    handleRuntimeEventSideEffects(event);
  }

  void handleRuntimeEventSideEffects(RuntimeEvent event) {}

  void _handleEventStreamFailure(Object error, StackTrace stackTrace) {
    _startup.fail(error);
    state = state.copyWith(
      isLoading: false,
      action: '',
      error: _message(error),
      problem: problemForError(error),
      startupSteps: _startup.stepsFor(_phase, error: error),
    );
  }

  bool _isFatalStartupError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('engine actor failed') ||
        normalized.contains('engine_fatal') ||
        normalized.contains('sqlite') ||
        normalized.contains('database') ||
        normalized.contains('identity') && normalized.contains('failed') ||
        normalized.contains('integrity_check') ||
        normalized.contains('private key');
  }

  void _scheduleEventRefresh() {
    if (_warming) {
      _refreshAfterWarmup = true;
      return;
    }
    _eventRefreshQueued = true;
    if (_eventRefreshInFlight != null) return;

    final run = _drainEventRefreshes();
    _eventRefreshInFlight = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_eventRefreshInFlight, run)) {
          _eventRefreshInFlight = null;
        }
        if (_eventRefreshQueued) _scheduleEventRefresh();
      }),
    );
  }

  Future<void> _drainEventRefreshes() async {
    while (_eventRefreshQueued && !_warming) {
      _eventRefreshQueued = false;
      try {
        final includePairing = _eventRefreshNeedsPairing;
        _eventRefreshNeedsPairing = false;
        final messageRefreshes = Set<String>.of(_eventMessageRefreshes);
        _eventMessageRefreshes.removeAll(messageRefreshes);
        // Message projections are latency-sensitive and must be serialized.
        // Refreshing the broad application snapshot first delayed the open
        // chat behind contacts, pairing and endpoint queries and allowed a
        // second event wave to race the first projection.
        for (final conversationId in messageRefreshes.toList()..sort()) {
          await _repository.messages(conversationId, force: true);
        }
        await refreshData(forcePairing: includePairing, allowAutoTorka: false);
      } catch (error) {
        state = state.copyWith(
          error: _message(error),
          problem: problemForError(error),
        );
      }
    }
  }

  void _applyTyping(Map<String, dynamic> payload) {
    final conversationId = payload[EngineContract.conversationId]?.toString();
    if (conversationId == null || conversationId.isEmpty) return;
    final typing = payload[EngineContract.typing] == true;
    _typingExpiry.remove(conversationId)?.cancel();
    state = state.copyWith(
      typingContacts: {...state.typingContacts, conversationId: typing},
    );
    if (typing) {
      _typingExpiry[conversationId] = Timer(const Duration(seconds: 5), () {
        state = state.copyWith(
          typingContacts: {...state.typingContacts, conversationId: false},
        );
        _typingExpiry.remove(conversationId);
      });
    }
  }

  void _applyConversationFocus(Map<String, dynamic> payload) {
    final conversationId = payload[EngineContract.conversationId]?.toString();
    if (conversationId == null || conversationId.isEmpty) return;
    // Focus expiry is owned by ContactProbeCoordinator.
  }

  String _message(Object error) => error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('Bad state: ', '')
      .replaceFirst('TimeoutException: ', '');

  Future<void> _notificationBeep() async {
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('torchat.notifications.enabled') ?? true) ||
        !(preferences.getBool('torchat.notifications.sound') ?? true)) {
      return;
    }
    if (Platform.isAndroid) return;
    if (Platform.isWindows) {
      const channel = MethodChannel('org.torchat/desktop-notifications');
      try {
        await channel.invokeMethod<void>('pagerBeep');
        return;
      } on MissingPluginException {
        // Use the Flutter fallback below.
      } on PlatformException {
        // Use the Flutter fallback below.
      }
    }
    await SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _playIntro() async {
    try {
      const channel = MethodChannel('org.torchat/audio');
      await channel.invokeMethod<void>('playIntro');
    } on MissingPluginException {
      // Widget tests and unsupported desktop platforms have no audio plugin.
    } on PlatformException {
      // Onboarding audio is optional and never changes startup readiness.
    }
  }
}
