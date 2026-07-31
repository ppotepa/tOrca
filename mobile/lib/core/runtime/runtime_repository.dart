import 'dart:async';
import 'dart:collection';

import '../../client_runtime.dart';
import '../application_state/application_snapshot.dart';
import '../application_state/application_state_store.dart';
import 'generated/runtime_contract.g.dart';
import 'refresh_coordinator.dart';

final class RuntimeLocalSnapshot {
  const RuntimeLocalSnapshot({
    required this.contacts,
    required this.conversations,
    required this.peerEndpointAvailable,
    required this.generation,
  });

  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final bool peerEndpointAvailable;
  final int generation;
}

final class RuntimePairingSnapshot {
  const RuntimePairingSnapshot({
    required this.inbox,
    required this.outbox,
    required this.generation,
  });

  final List<PairingItem> inbox;
  final List<PairingItem> outbox;
  final int generation;
}

final class RuntimeRefreshSnapshot {
  const RuntimeRefreshSnapshot({required this.local, this.pairing});

  final RuntimeLocalSnapshot local;
  final RuntimePairingSnapshot? pairing;
}

enum ConversationMessagesPhase { idle, loading, ready, failed }

final class ConversationMessagesLoadState {
  const ConversationMessagesLoadState({
    required this.conversationId,
    required this.phase,
    this.error = '',
  });

  final String conversationId;
  final ConversationMessagesPhase phase;
  final String error;
}

class RuntimeRepository {
  RuntimeRepository(this._runtime);

  static const int _messageCacheLimit = 5;

  final ClientRuntime _runtime;
  final RefreshCoordinator _refreshCoordinator = RefreshCoordinator();
  final ApplicationStateStore applicationState = ApplicationStateStore.shared;
  final LinkedHashMap<String, List<ChatMessage>> _messageCache =
      LinkedHashMap<String, List<ChatMessage>>();
  final StreamController<ConversationMessagesLoadState> _messageLoadController =
      StreamController<ConversationMessagesLoadState>.broadcast(sync: true);

  Future<RuntimeLocalSnapshot>? _localBatchInFlight;
  Future<RuntimePairingSnapshot>? _pairingBatchInFlight;
  Future<ApplicationSnapshot>? _applicationSnapshotInFlight;
  bool _applicationSnapshotIncludesPairing = false;
  RuntimeLocalSnapshot? _latestLocalSnapshot;
  RuntimePairingSnapshot? _latestPairingSnapshot;
  DateTime? _localCacheTime;
  DateTime? _pairingCacheTime;
  Timer? _snapshotRefreshDebounce;
  bool _snapshotRefreshNeedsPairing = false;
  int _snapshotGeneration = 0;
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;

  late final Stream<RuntimeEvent> _events = _runtime.events.map((event) {
    _invalidateCachesForEvent(event);
    return event;
  }).asBroadcastStream();

  Stream<RuntimeEvent> get events => _events;
  Stream<ApplicationSnapshot?> get applicationSnapshots => applicationState.changes;
  Stream<ConversationMessagesLoadState> get messageLoadStates =>
      _messageLoadController.stream;

  Future<bool> connect() async {
    final connected = await _runtime.connect();
    _lastTyping.clear();
    _lastPresence = null;

    final nativeIdentity = await _runtime.identity();
    final retained = applicationState.current;
    final identityChanged =
        retained != null &&
        nativeIdentity != null &&
        nativeIdentity.installationId.isNotEmpty &&
        retained.identity.installationId != nativeIdentity.installationId;
    if (identityChanged) {
      applicationState.clear();
      _latestLocalSnapshot = null;
      _latestPairingSnapshot = null;
      _messageCache.clear();
    }

    if (applicationState.hasSnapshot) {
      _refreshApplicationSnapshotInBackground();
    } else {
      try {
        await applicationSnapshot(force: true);
      } catch (_) {
        // Existing identity/profile calls remain the compatibility fallback.
      }
    }
    return connected;
  }

  Future<RuntimeIdentity> identity() async =>
      applicationState.current?.identity ??
      await _runtime.identity() ??
      const RuntimeIdentity();

  Future<RuntimeProfile> profile() async =>
      applicationState.current?.profile ??
      await _runtime.profile() ??
      const RuntimeProfile();

  Future<RuntimeProfile> setNickname(String value) async {
    final profile = await _runtime.setNickname(value);
    final current = applicationState.current;
    if (current != null) {
      applicationState.hydrate(
        current.copyWith(
          profile: profile,
          generation: _nextGeneration(current.generation),
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return profile;
  }

  Future<InviteCode?> refreshInviteCode() => _runtime.refreshPairingCode();

  Future<ApplicationSnapshot> applicationSnapshot({
    bool includePairing = false,
    bool force = false,
  }) {
    final cached = applicationState.current;
    if (!force && cached != null && !applicationState.isStale) {
      return Future.value(cached);
    }

    final inFlight = _applicationSnapshotInFlight;
    if (inFlight != null) {
      if (!includePairing || _applicationSnapshotIncludesPairing) return inFlight;
      return inFlight.then(
        (_) => applicationSnapshot(includePairing: true, force: true),
      );
    }

    _applicationSnapshotIncludesPairing = includePairing;
    final request = _buildApplicationSnapshot(includePairing: includePairing);
    _applicationSnapshotInFlight = request;
    return request.whenComplete(() {
      if (identical(_applicationSnapshotInFlight, request)) {
        _applicationSnapshotInFlight = null;
        _applicationSnapshotIncludesPairing = false;
      }
    });
  }

  Future<ApplicationSnapshot> _buildApplicationSnapshot({
    required bool includePairing,
  }) async {
    final values = await Future.wait<Object>([
      _runtime.identity().then((value) => value ?? const RuntimeIdentity()),
      _runtime.profile().then((value) => value ?? const RuntimeProfile()),
      _loadLocalBatch(force: true),
      if (includePairing) _loadPairingBatch(force: true),
    ]);

    final identityValue = values[0] as RuntimeIdentity;
    final profileValue = values[1] as RuntimeProfile;
    final local = values[2] as RuntimeLocalSnapshot;
    final pairing = includePairing && values.length > 3
        ? values[3] as RuntimePairingSnapshot
        : _latestPairingSnapshot;

    final contacts = [...local.contacts]
      ..sort((left, right) {
        final leftName = left.displayName.toLowerCase();
        final rightName = right.displayName.toLowerCase();
        final byName = leftName.compareTo(rightName);
        return byName != 0 ? byName : left.id.compareTo(right.id);
      });
    final conversations = [...local.conversations]
      ..sort((left, right) {
        final byTime = right.lastMessageAt.compareTo(left.lastMessageAt);
        return byTime != 0 ? byTime : left.id.compareTo(right.id);
      });

    final snapshot = ApplicationSnapshot(
      generation: _nextGeneration(local.generation),
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      identity: identityValue,
      profile: profileValue,
      contacts: List.unmodifiable(contacts),
      conversations: List.unmodifiable(conversations),
      pendingInbox: pairing?.inbox.pendingCount ??
          applicationState.current?.pendingInbox ??
          0,
      pendingOutbox: pairing?.outbox
              .where(
                (item) =>
                    item.status == InviteState.pending ||
                    item.status == InviteState.accepted,
              )
              .length ??
          applicationState.current?.pendingOutbox ??
          0,
      peerEndpointAvailable: local.peerEndpointAvailable,
    );
    applicationState.hydrate(snapshot);
    return snapshot;
  }

  int _nextGeneration([int minimum = 0]) {
    final current = applicationState.current?.generation ?? 0;
    _snapshotGeneration = [
      _snapshotGeneration + 1,
      current + 1,
      minimum + 1,
    ].reduce((left, right) => left > right ? left : right);
    return _snapshotGeneration;
  }

  Future<RuntimeRefreshSnapshot> refresh({
    bool includePairing = false,
    bool bypassCooldown = false,
  }) async {
    if (bypassCooldown) {
      final local = await _loadLocalBatch(force: true);
      final pairing = includePairing
          ? await _loadPairingBatch(force: true)
          : null;
      await applicationSnapshot(includePairing: includePairing, force: true);
      return RuntimeRefreshSnapshot(local: local, pairing: pairing);
    }

    await _refreshCoordinator.schedule(
      includeRemote: includePairing,
      local: (_) async {
        await _loadLocalBatch(force: true);
      },
      remote: (_) async {
        await _loadPairingBatch(force: true);
      },
    );
    final local = _latestLocalSnapshot;
    if (local == null) {
      throw StateError('Local runtime refresh produced no snapshot');
    }
    await applicationSnapshot(includePairing: includePairing, force: true);
    return RuntimeRefreshSnapshot(
      local: local,
      pairing: includePairing ? _latestPairingSnapshot : null,
    );
  }

  bool get _localCacheFresh {
    final time = _localCacheTime;
    return time != null &&
        DateTime.now().difference(time) < const Duration(seconds: 2);
  }

  bool get _pairingCacheFresh {
    final time = _pairingCacheTime;
    return time != null &&
        DateTime.now().difference(time) < const Duration(seconds: 10);
  }

  Future<RuntimeLocalSnapshot> _loadLocalBatch({bool force = false}) {
    if (!force && _localCacheFresh && _latestLocalSnapshot != null) {
      return Future.value(_latestLocalSnapshot!);
    }

    final retained = applicationState.current;
    if (!force && retained != null && !applicationState.isStale) {
      final snapshot = RuntimeLocalSnapshot(
        contacts: retained.contacts,
        conversations: retained.conversations,
        peerEndpointAvailable: retained.peerEndpointAvailable,
        generation: retained.generation,
      );
      _latestLocalSnapshot = snapshot;
      _localCacheTime = DateTime.now();
      return Future.value(snapshot);
    }

    final current = _localBatchInFlight;
    if (current != null) return current;
    final generation = _nextGeneration();
    final request = Future.wait<Object>([
      _runtime.contacts(),
      _runtime.conversations(),
      _runtime.peerEndpointAvailable(),
    ]).then((values) {
      final snapshot = RuntimeLocalSnapshot(
        contacts: List.unmodifiable(values[0] as List<ContactRecord>),
        conversations:
            List.unmodifiable(values[1] as List<ConversationSummary>),
        peerEndpointAvailable: values[2] as bool,
        generation: generation,
      );
      _latestLocalSnapshot = snapshot;
      _localCacheTime = DateTime.now();
      return snapshot;
    });
    _localBatchInFlight = request;
    return request.whenComplete(() {
      if (identical(_localBatchInFlight, request)) _localBatchInFlight = null;
    });
  }

  Future<RuntimePairingSnapshot> _loadPairingBatch({bool force = false}) {
    if (!force && _pairingCacheFresh && _latestPairingSnapshot != null) {
      return Future.value(_latestPairingSnapshot!);
    }
    final current = _pairingBatchInFlight;
    if (current != null) return current;
    final generation = _nextGeneration();
    final request = Future.wait<Object>([
      _runtime.pairingInbox(),
      _runtime.pairingOutbox(),
    ]).then((values) {
      final snapshot = RuntimePairingSnapshot(
        inbox: List.unmodifiable(values[0] as List<PairingItem>),
        outbox: List.unmodifiable(values[1] as List<PairingItem>),
        generation: generation,
      );
      _latestPairingSnapshot = snapshot;
      _pairingCacheTime = DateTime.now();
      return snapshot;
    });
    _pairingBatchInFlight = request;
    return request.whenComplete(() {
      if (identical(_pairingBatchInFlight, request)) {
        _pairingBatchInFlight = null;
      }
    });
  }

  void invalidateLocalCache({bool markSnapshotStale = true}) {
    _localCacheTime = null;
    _latestLocalSnapshot = null;
    if (markSnapshotStale) applicationState.markStale();
  }

  void invalidatePairingCache({bool markSnapshotStale = true}) {
    _pairingCacheTime = null;
    _latestPairingSnapshot = null;
    if (markSnapshotStale) applicationState.markStale();
  }

  void _invalidateCachesForEvent(RuntimeEvent event) {
    var refreshShell = false;
    var includePairing = false;
    switch (event) {
      case ProfileReadyEvent():
      case PeerEndpointChangedEvent():
      case PeerConnectionChangedEvent():
        invalidateLocalCache();
        refreshShell = true;
      case DataChangedEvent(:final type):
        invalidateLocalCache();
        refreshShell = true;
        if (type == EngineContract.inviteReceived ||
            type == EngineContract.inviteStateChanged) {
          invalidatePairingCache();
          includePairing = true;
        }
        if (type.startsWith('messages:')) {
          invalidateMessages(type.substring('messages:'.length));
        }
      default:
        break;
    }
    if (refreshShell) {
      _scheduleApplicationSnapshotRefresh(includePairing: includePairing);
    }
  }

  void _scheduleApplicationSnapshotRefresh({bool includePairing = false}) {
    _snapshotRefreshNeedsPairing =
        _snapshotRefreshNeedsPairing || includePairing;
    _snapshotRefreshDebounce?.cancel();
    _snapshotRefreshDebounce = Timer(const Duration(milliseconds: 160), () {
      final withPairing = _snapshotRefreshNeedsPairing;
      _snapshotRefreshNeedsPairing = false;
      _refreshApplicationSnapshotInBackground(includePairing: withPairing);
    });
  }

  void _refreshApplicationSnapshotInBackground({bool includePairing = false}) {
    unawaited(
      applicationSnapshot(includePairing: includePairing, force: true)
          .then<void>((_) {})
          .catchError((Object _, StackTrace __) {}),
    );
  }

  void _warmPairingCache() {
    unawaited(
      _loadPairingBatch()
          .then<void>((_) {
            _refreshApplicationSnapshotInBackground(includePairing: true);
          })
          .catchError((Object _, StackTrace __) {}),
    );
  }

  Future<PairingItem> submitPairingCode(String code) async {
    final item = await _runtime.submitPairingCode(code);
    invalidatePairingCache();
    _scheduleApplicationSnapshotRefresh(includePairing: true);
    return item;
  }

  Future<void> acceptPairing(String id) async {
    await _runtime.acceptPairing(id);
    invalidatePairingCache();
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh(includePairing: true);
  }

  Future<void> rejectPairing(String id) async {
    await _runtime.rejectPairing(id);
    invalidatePairingCache();
    _scheduleApplicationSnapshotRefresh(includePairing: true);
  }

  Future<void> archiveInvite(String id) async {
    await _runtime.archivePairing(id);
    invalidatePairingCache();
    _scheduleApplicationSnapshotRefresh(includePairing: true);
  }

  Future<void> cancelPairing(String id) async {
    await _runtime.cancelPairing(id);
    invalidatePairingCache();
    _scheduleApplicationSnapshotRefresh(includePairing: true);
  }

  Future<void> verifyContact(String id) async {
    await _runtime.verifyContact(id);
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<ContactRecord> updateContactSettings(
    String id, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) async {
    final contact = await _runtime.updateContactSettings(
      id,
      localAlias: localAlias,
      muted: muted,
      blocked: blocked,
      transportPolicy: transportPolicy,
    );
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
    return contact;
  }

  Future<List<ContactRecord>> contacts() async =>
      (await _loadLocalBatch()).contacts;

  Future<List<ConversationSummary>> conversations() async =>
      (await _loadLocalBatch()).conversations;

  Future<List<ChatMessage>> messages(String id, {bool force = false}) {
    if (!force) {
      final cached = _messageCache.remove(id);
      if (cached != null) {
        _messageCache[id] = cached;
        return Future.value(cached);
      }
    }
    final current = _messagesInFlight[id];
    if (current != null) return current;

    _messageLoadController.add(
      ConversationMessagesLoadState(
        conversationId: id,
        phase: ConversationMessagesPhase.loading,
      ),
    );
    final request = _loadMessages(id);
    _messagesInFlight[id] = request;
    return request.whenComplete(() {
      if (identical(_messagesInFlight[id], request)) {
        _messagesInFlight.remove(id);
      }
    });
  }

  Future<List<ChatMessage>> _loadMessages(String id) async {
    try {
      final messages = await _runtime.messages(id);
      final immutable = List<ChatMessage>.unmodifiable(messages);
      _messageCache[id] = immutable;
      while (_messageCache.length > _messageCacheLimit) {
        _messageCache.remove(_messageCache.keys.first);
      }
      _messageLoadController.add(
        ConversationMessagesLoadState(
          conversationId: id,
          phase: ConversationMessagesPhase.ready,
        ),
      );
      return immutable;
    } catch (error, stackTrace) {
      _messageLoadController.add(
        ConversationMessagesLoadState(
          conversationId: id,
          phase: ConversationMessagesPhase.failed,
          error: error.toString(),
        ),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void invalidateMessages([String? conversationId]) {
    if (conversationId == null || conversationId.isEmpty) {
      _messageCache.clear();
      return;
    }
    _messageCache.remove(conversationId);
  }

  Future<List<PairingItem>> inbox({bool force = false}) async {
    if (force) return (await _loadPairingBatch(force: true)).inbox;
    final current = _latestPairingSnapshot;
    if (current != null) return current.inbox;
    _warmPairingCache();
    return const [];
  }

  Future<List<PairingItem>> outbox({bool force = false}) async {
    if (force) return (await _loadPairingBatch(force: true)).outbox;
    final current = _latestPairingSnapshot;
    if (current != null) return current.outbox;
    _warmPairingCache();
    return const [];
  }

  Future<PeerEndpoint?> peerEndpoint() => _runtime.peerEndpoint();

  Future<bool> peerEndpointAvailable() async =>
      (await _loadLocalBatch()).peerEndpointAvailable;

  Future<void> retryPeerConnection(String installationId) async {
    await _runtime.retryPeerConnection(installationId);
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> rotatePeerEndpoint() async {
    await _runtime.rotatePeerEndpoint();
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> openConversation(String id) async {
    await _runtime.openConversation(id);
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> closeConversation() => _runtime.closeConversation();

  Future<void> startConversation(String id) async {
    await _runtime.startConversation(id);
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {
    await _runtime.sendMessage(id, text, replyToMessageId: replyToMessageId);
    invalidateMessages(id);
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> retryMessage(String messageId) async {
    await _runtime.retryMessage(messageId);
    invalidateMessages();
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> deleteMessageLocal(String messageId) async {
    await _runtime.deleteMessageLocal(messageId);
    invalidateMessages();
    invalidateLocalCache();
    _scheduleApplicationSnapshotRefresh();
  }

  Future<void> setTyping(String conversationId, bool typing) async {
    if (_lastTyping[conversationId] == typing) return;
    _lastTyping[conversationId] = typing;
    try {
      await _runtime.setTyping(conversationId, typing);
    } catch (_) {
      if (_lastTyping[conversationId] == typing) {
        _lastTyping.remove(conversationId);
      }
      rethrow;
    }
  }

  Future<void> setPresence(bool online) async {
    if (_lastPresence == online) return;
    _lastPresence = online;
    try {
      await _runtime.setPresence(online);
    } catch (_) {
      if (_lastPresence == online) _lastPresence = null;
      rethrow;
    }
  }

  Future<void> sendReadReceipts(String conversationId) =>
      _runtime.sendReadReceipts(conversationId);

  Future<void> updateAppVisibility(bool foreground) =>
      _runtime.updateAppVisibility(foreground);
}
