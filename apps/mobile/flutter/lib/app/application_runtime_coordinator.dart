import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_flutter_ui/core/runtime/generated/runtime_contract.g.dart';
import '../client_runtime.dart';
import '../core/presence/contact_probe_coordinator.dart';
import '../core/presence/contact_presence_store.dart';
import '../core/runtime/runtime_repository.dart';
import '../core/startup/sequential_startup_orchestrator.dart';
import '../locales/domain/user_problem.dart';
import '../shared/formatters/operation_status.dart';
import 'application_state.dart';

class ApplicationRuntimeCoordinator {
  ApplicationRuntimeCoordinator({
    required ClientRuntime runtime,
    required RuntimeRepository repository,
    required ContactPresenceStore contactPresence,
    required AppState Function() readState,
    required void Function(AppState) writeState,
    required Future<void> Function() refreshCore,
    required String Function(Object) messageForError,
    required UserProblem Function(Object) problemForError,
    required void Function(RuntimeEvent) handleSideEffects,
  }) : _runtime = runtime,
       _repository = repository,
       _readState = readState,
       _writeState = writeState,
       _refreshCore = refreshCore,
       _messageForError = messageForError,
       _problemForError = problemForError,
       _handleSideEffects = handleSideEffects,
       _presenceCoordinator = ContactProbeCoordinator(contactPresence);
  final ClientRuntime _runtime;
  final RuntimeRepository _repository;
  final AppState Function() _readState;
  final void Function(AppState) _writeState;
  final Future<void> Function() _refreshCore;
  final String Function(Object) _messageForError;
  final UserProblem Function(Object) _problemForError;
  final void Function(RuntimeEvent) _handleSideEffects;
  final ContactProbeCoordinator _presenceCoordinator;
  AppState get state => _readState();
  set state(AppState value) => _writeState(value);
  void dispose() {
    _startup.cancel();
    unawaited(_events?.cancel());
    _presenceCoordinator.dispose();
    for (final timer in _typingExpiry.values) {
      timer.cancel();
    }
  }

  final SequentialStartupOrchestrator _startup =
      SequentialStartupOrchestrator();
  final Map<String, Timer> _typingExpiry = {};
  StreamSubscription<RuntimeEvent>? _events;
  Future<void>? _initializeInFlight;
  Future<void> _refreshTail = Future<void>.value();
  Future<void>? _eventRefreshInFlight;
  final Set<String> _eventMessageRefreshes = <String>{};
  bool _eventRefreshQueued = false;
  bool _refreshAfterWarmup = false;
  bool _warming = false;
  bool _startupComplete = false;
  bool _introPlayed = false;
  SequentialStartupPhase _phase = SequentialStartupPhase.engine;
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
      screen: ControllerScreen.boot,
      isLoading: true,
      action: OperationAction.connect,
      error: '',
      peerServerStatus: PeerServerStatus.starting,
    );

    try {
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
        _repository.invalidateMessages();
      }
      state = state.copyWith(
        applicationSnapshot: snapshot,
        peerServerStatus: snapshot.peerEndpointAvailable
            ? PeerServerStatus.ready
            : PeerServerStatus.starting,
        isLoading: false,
        screen: snapshot.profile.nickname.trim().isNotEmpty
            ? ControllerScreen.main
            : ControllerScreen.nickname,
      );
      localShellReady = true;
      _startupComplete = true;
      _startup.observePeerEndpoint(snapshot.peerEndpointAvailable);

      state = state.copyWith(
        applicationSnapshot: snapshot,
        startupSteps: _startup.stepsFor(SequentialStartupPhase.localData),
        peerServerStatus: snapshot.peerEndpointAvailable
            ? PeerServerStatus.ready
            : PeerServerStatus.starting,
        screen: snapshot.profile.nickname.trim().isNotEmpty
            ? ControllerScreen.main
            : ControllerScreen.nickname,
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
        error: _messageForError(error),
        problem: _problemForError(error),
        startupSteps: _startup.stepsFor(_phase, error: _messageForError(error)),
        screen: localShellReady
            ? (state.profile.nickname.trim().isNotEmpty
                  ? ControllerScreen.main
                  : ControllerScreen.nickname)
            : ControllerScreen.boot,
      );
    } finally {
      if (_startup.generation == generation) {
        _warming = false;
        if (_startupComplete) {
          _refreshAfterWarmup = false;
          unawaited(refreshData());
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

  Future<void> refreshData() {
    if (_warming) {
      _refreshAfterWarmup = true;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _refreshTail = _refreshTail.catchError((Object _) {}).then<void>((_) async {
      try {
        await _refreshCore();
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
          if (contactId == null || contactId.isEmpty) break;
        } else {
          if (type == EngineContract.projectionChanged) {
            final incomingRevision =
                (payload[EngineContract.revision] as num?)?.toInt() ?? 0;
            final currentRevision =
                _repository.applicationState.current?.projectionRevision ?? 0;
            if (incomingRevision > 0 && incomingRevision <= currentRevision) {
              break;
            }
          }
          _repository.invalidateLocalCache();
          final changeKind = type == EngineContract.changed
              ? payload[EngineContract.kind]?.toString() ?? ''
              : type;
          if (type == EngineContract.messageReceived ||
              type == EngineContract.messageStateChanged) {
            final conversationId = payload[EngineContract.conversationId]
                ?.toString();
            if (conversationId != null && conversationId.isNotEmpty) {
              _repository.invalidateMessages(conversationId);
              _eventMessageRefreshes.add(conversationId);
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
      case NotificationRequestedEvent():
        unawaited(_notificationBeep());
    }
    _handleSideEffects(event);
  }

  void _handleEventStreamFailure(Object error, StackTrace stackTrace) {
    _startup.fail(error);
    state = state.copyWith(
      isLoading: false,
      action: '',
      error: _messageForError(error),
      problem: _problemForError(error),
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
        final messageRefreshes = Set<String>.of(_eventMessageRefreshes);
        _eventMessageRefreshes.removeAll(messageRefreshes);
        for (final conversationId in messageRefreshes.toList()..sort()) {
          await _repository.messages(conversationId, force: true);
        }
        await refreshData();
      } catch (error) {
        state = state.copyWith(
          error: _messageForError(error),
          problem: _problemForError(error),
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
  }

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
