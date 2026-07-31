import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/runtime/generated/runtime_contract.g.dart';
import '../core/runtime/runtime_repository.dart';
import '../core/startup/sequential_startup_orchestrator.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_legacy.dart' as legacy;

class SequentialAppController extends legacy.AppController {
  final SequentialStartupOrchestrator _startup =
      SequentialStartupOrchestrator();
  final Map<String, Timer> _typingExpiry = {};

  late RuntimeRepository _repository;
  StreamSubscription<RuntimeEvent>? _events;
  Future<void>? _initializeInFlight;
  Future<void> _refreshTail = Future<void>.value();
  Future<void>? _eventRefreshInFlight;
  bool _eventRefreshQueued = false;
  bool _refreshAfterWarmup = false;
  bool _warming = false;
  bool _startupComplete = false;
  SequentialStartupPhase _phase = SequentialStartupPhase.engine;

  @override
  legacy.AppState build() {
    final initial = super.build();
    _repository = ref.read(legacy.runtimeRepositoryProvider);
    ref.onDispose(() {
      _startup.cancel();
      _events?.cancel();
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

  Future<void> _runSequentialWarmup() async {
    _events ??= _repository.events.listen(_handleSequentialEvent);
    final generation = _startup.begin(
      transport: state.transport,
      runtimeReady: state.identity.installationId.isNotEmpty,
      peerEndpointAvailable:
          state.peerServerStatus == PeerServerStatus.ready,
    );
    _warming = true;
    _startupComplete = false;
    _applyPhase(SequentialStartupPhase.engine);
    state = state.copyWith(
      screen: legacy.ControllerScreen.boot,
      isLoading: true,
      action: OperationAction.connect,
      error: '',
      notice: '',
      peerServerStatus: PeerServerStatus.starting,
    );

    try {
      await _repository.connect().timeout(const Duration(seconds: 60));
      _ensureGeneration(generation);
      // The actor accepts commands only after binding the local peer listener.
      // Keep this fact even when the runtime-ready event arrived before the
      // Flutter event subscription was fully established.
      _startup.observeRuntimeReady();

      _applyPhase(SequentialStartupPhase.localData);
      final snapshot = await _repository
          .applicationSnapshot(force: true)
          .timeout(const Duration(seconds: 30));
      _ensureGeneration(generation);
      if (snapshot.peerEndpointAvailable) {
        _startup.observePeerEndpoint(true);
      }
      final profile = snapshot.profile;
      state = state.copyWith(
        identity: snapshot.identity,
        profile: profile,
        contacts: _mergeContacts(snapshot.contacts),
        conversations: snapshot.conversations,
        peerServerStatus: snapshot.peerEndpointAvailable
            ? PeerServerStatus.ready
            : PeerServerStatus.starting,
        isLoading: false,
        // Returning users may use their local shell while Tor continues its
        // deterministic warmup in the background.
        screen: profile.nickname.trim().isNotEmpty
            ? legacy.ControllerScreen.main
            : legacy.ControllerScreen.boot,
      );

      _applyPhase(SequentialStartupPhase.tor);
      await _startup.waitForTor(generation);
      _ensureGeneration(generation);

      _applyPhase(SequentialStartupPhase.relay);
      await _startup.waitForRelay(generation);
      _ensureGeneration(generation);

      _applyPhase(SequentialStartupPhase.peerListener);
      await _startup.waitForPeerListener(generation);
      _ensureGeneration(generation);

      _applyPhase(SequentialStartupPhase.onionService);
      await _waitForOnionService(generation);
      _ensureGeneration(generation);

      _applyPhase(SequentialStartupPhase.communication);
      await Future<void>.delayed(Duration.zero);
      _ensureGeneration(generation);

      _phase = SequentialStartupPhase.complete;
      _startupComplete = true;
      state = state.copyWith(
        startupSteps: _startup.stepsFor(SequentialStartupPhase.complete),
        peerServerStatus: PeerServerStatus.ready,
        screen: state.profile.nickname.trim().isNotEmpty
            ? legacy.ControllerScreen.main
            : legacy.ControllerScreen.nickname,
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
        startupSteps: _startup.stepsFor(
          _phase,
          error: _message(error),
        ),
        screen: state.profile.nickname.trim().isNotEmpty
            ? legacy.ControllerScreen.main
            : legacy.ControllerScreen.boot,
      );
    } finally {
      if (_startup.generation == generation) {
        _warming = false;
        if (_refreshAfterWarmup) {
          _refreshAfterWarmup = false;
          _scheduleEventRefresh();
        }
      }
    }
  }

  Future<void> _waitForOnionService(int generation) async {
    final deadline = DateTime.now().add(const Duration(minutes: 1));
    while (!_startup.onionServiceReady) {
      _ensureGeneration(generation);
      final available = await _repository.peerEndpointAvailable();
      if (available) {
        _startup.observePeerEndpoint(true);
        break;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Lokalna usługa onion nie została opublikowana',
          const Duration(minutes: 1),
        );
      }
      try {
        await _startup.waitForOnionService(
          generation,
          timeout: remaining < const Duration(milliseconds: 500)
              ? remaining
              : const Duration(milliseconds: 500),
        );
      } on TimeoutException {
        // Polling is a compatibility fallback for desktop builds where the
        // endpoint event was emitted before Flutter attached.
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
    state = state.copyWith(
      startupSteps: _startup.stepsFor(phase),
      error: '',
    );
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
    switch (event) {
      case RuntimeReadyEvent():
        _startup.observeRuntimeReady();
      case TorStatusEvent(:final snapshot):
        _startup.observeTransport(snapshot);
        state = state.copyWith(
          transport: snapshot,
          error: snapshot.phase.isError ? state.error : '',
          screen: state.profile.nickname.trim().isNotEmpty
              ? legacy.ControllerScreen.main
              : state.screen,
        );
      case ProfileReadyEvent(:final profile):
        final current = state.profile;
        final next = profile.nickname.trim().isEmpty &&
                current.nickname.trim().isNotEmpty
            ? current
            : profile;
        state = state.copyWith(profile: next, error: '');
      case DataChangedEvent(:final type, :final payload):
        if (type == EngineContract.typingChanged) {
          _applyTyping(payload);
        } else if (type == EngineContract.presenceChanged) {
          final contactId = payload[EngineContract.contactId]?.toString();
          if (contactId != null && contactId.isNotEmpty) {
            state = state.copyWith(
              onlineContacts: {
                ...state.onlineContacts,
                contactId: payload[EngineContract.online] == true,
              },
            );
          }
        } else {
          _scheduleEventRefresh();
        }
      case PeerEndpointChangedEvent(:final contactId, :final status):
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
      case PeerConnectionChangedEvent(:final contactId, :final status):
        state = state.copyWith(
          contacts: [
            for (final contact in state.contacts)
              if (contact.id == contactId)
                contact.copyWith(peerConnectionStatus: status)
              else
                contact,
          ],
        );
      case RuntimeErrorEvent(:final message):
        if (_isFatalStartupError(message)) {
          _startup.fail(StateError(message));
        }
        state = state.copyWith(error: message);
      case RuntimeLogEvent(:final message):
        final normalized = message.toLowerCase();
        if (normalized.contains('client engine actor started') ||
            normalized.contains('peer listener')) {
          _startup.observeRuntimeReady();
        }
        if (normalized.contains('onion service unavailable')) {
          final failure = StateError(message);
          _startup.fail(failure);
          state = state.copyWith(
            peerServerStatus: PeerServerStatus.offline,
            error: message,
          );
        }
      case NotificationRequestedEvent():
        unawaited(_notificationBeep());
    }
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
        await refreshData(allowAutoTorka: false);
        final selected = state.selectedConversationId;
        if (selected != null && selected.isNotEmpty) {
          state = state.copyWith(
            messages: await _repository.messages(selected, force: true),
          );
        }
      } catch (error) {
        state = state.copyWith(error: _message(error));
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

  List<ContactRecord> _mergeContacts(List<ContactRecord> refreshed) {
    final currentById = {
      for (final contact in state.contacts) contact.id: contact,
    };
    return [
      for (final contact in refreshed)
        if (currentById[contact.id] case final current?)
          contact.copyWith(
            peerConnectionStatus:
                contact.peerConnectionStatus == PeerConnectionStatus.offline &&
                    current.peerConnectionStatus != PeerConnectionStatus.offline
                ? current.peerConnectionStatus
                : contact.peerConnectionStatus,
            lastPeerConnectedAt:
                contact.lastPeerConnectedAt ?? current.lastPeerConnectedAt,
          )
        else
          contact,
    ];
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
}
