import 'dart:async';
import 'dart:collection';

import '../../client_runtime.dart';
import '../application_state/application_snapshot.dart';
import '../application_state/application_state_store.dart';
import 'message_paging.dart';

int _compareMessages(ChatMessage left, ChatMessage right) {
  final leftAt = DateTime.tryParse(left.createdAt)?.millisecondsSinceEpoch ?? 0;
  final rightAt =
      DateTime.tryParse(right.createdAt)?.millisecondsSinceEpoch ?? 0;
  final time = leftAt.compareTo(rightAt);
  return time != 0 ? time : left.id.compareTo(right.id);
}

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
  const RuntimeRefreshSnapshot({
    required this.application,
    required this.local,
    this.pairing,
  });

  final ApplicationSnapshot application;
  final RuntimeLocalSnapshot local;
  final RuntimePairingSnapshot? pairing;
}

final class ActivatedConversation {
  const ActivatedConversation({
    required this.conversation,
    required this.messages,
  });

  final ConversationSummary conversation;
  final List<ChatMessage> messages;
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
  final ApplicationStateStore applicationState = ApplicationStateStore.shared;

  ApplicationSnapshot? get currentApplicationSnapshot =>
      applicationState.current;

  RuntimePairingSnapshot? get currentPairingSnapshot => _latestPairingSnapshot;
  final LinkedHashMap<String, List<ChatMessage>> _messageCache =
      LinkedHashMap<String, List<ChatMessage>>();
  final StreamController<ConversationMessagesLoadState> _messageLoadController =
      StreamController<ConversationMessagesLoadState>.broadcast(sync: true);

  Future<RuntimeLocalSnapshot>? _localBatchInFlight;
  Future<RuntimePairingSnapshot>? _pairingBatchInFlight;
  Future<ApplicationSnapshot>? _applicationSnapshotInFlight;
  bool _applicationSnapshotIncludesPairing = false;
  bool _applicationTrailingRefreshRequested = false;
  bool _applicationTrailingIncludesPairing = false;
  bool _cachedApplicationSnapshotIncludesPairing = false;
  RuntimeLocalSnapshot? _latestLocalSnapshot;
  RuntimePairingSnapshot? _latestPairingSnapshot;
  DateTime? _localCacheTime;
  DateTime? _pairingCacheTime;
  int _snapshotGeneration = 0;
  int _localInvalidationEpoch = 0;
  final Map<String, int> _messageInvalidationEpoch = <String, int>{};
  final Map<String, int> _messageRequestSequence = <String, int>{};
  final Map<String, int> _messageAppliedSequence = <String, int>{};
  final Map<String, PeerConnectionStatus> _livePeerStatuses =
      <String, PeerConnectionStatus>{};
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Set<String> _messageTrailingRefreshRequested = <String>{};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;

  // Runtime events have exactly one consumer-side coordinator. Cache
  // invalidation and projection refresh are owned by SequentialAppController;
  // performing them here as well caused competing refreshes and stale UI.
  late final Stream<RuntimeEvent> _events = _runtime.events
      .map(_recordLiveEventState)
      .asBroadcastStream();

  Stream<RuntimeEvent> get events => _events;
  Stream<ApplicationSnapshot?> get applicationSnapshots =>
      applicationState.changes;
  Stream<ConversationMessagesLoadState> get messageLoadStates =>
      _messageLoadController.stream;

  RuntimeEvent _recordLiveEventState(RuntimeEvent event) {
    if (event case PeerConnectionChangedEvent(
      :final contactId,
      :final status,
    )) {
      _livePeerStatuses[contactId] = status;
    }
    return event;
  }

  Future<bool> connect() async {
    final connected = await _runtime.connect();
    _lastTyping.clear();
    _lastPresence = null;
    _livePeerStatuses.clear();

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
      await applicationSnapshot(force: true);
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

  Future<RuntimeMessagePage> messagePage(
    String conversationId, {
    ChatMessage? before,
    int limit = defaultMessagePageSize,
  }) => _runtime.messagePage(conversationId, before: before, limit: limit);

  Future<List<ChatMessage>> allMessages(String conversationId) =>
      _runtime.allMessages(conversationId);

  /// Applies a user-requested older page through the repository owner. UI
  /// controllers must not mutate the projection store directly, otherwise a
  /// concurrent message/status refresh can overwrite or resurrect history.
  Future<int> mergeOlderMessagePage(
    String conversationId,
    RuntimeMessagePage page,
  ) async {
    final current = applicationState.messages(conversationId);
    final knownIds = current.map((message) => message.id).toSet();
    final added = page.messages
        .where((message) => knownIds.add(message.id))
        .toList(growable: false);
    if (added.isEmpty) return 0;
    final merged = <ChatMessage>[...added, ...current]..sort(_compareMessages);
    applicationState.mergeMessages(conversationId, merged);
    _messageCache[conversationId] = List<ChatMessage>.unmodifiable(merged);
    return added.length;
  }

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
    if (!force &&
        cached != null &&
        !applicationState.isStale &&
        (!includePairing || _cachedApplicationSnapshotIncludesPairing)) {
      return Future.value(cached);
    }

    final inFlight = _applicationSnapshotInFlight;
    if (inFlight != null) {
      if (force) {
        _applicationTrailingRefreshRequested = true;
        _applicationTrailingIncludesPairing =
            _applicationTrailingIncludesPairing || includePairing;
        return inFlight.then((snapshot) {
          if (!_applicationTrailingRefreshRequested) return snapshot;
          final trailingIncludesPairing = _applicationTrailingIncludesPairing;
          _applicationTrailingRefreshRequested = false;
          _applicationTrailingIncludesPairing = false;
          return applicationSnapshot(
            includePairing: trailingIncludesPairing,
            force: true,
          );
        });
      }
      if (!includePairing || _applicationSnapshotIncludesPairing) {
        return inFlight;
      }
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
        _cachedApplicationSnapshotIncludesPairing =
            _applicationSnapshotIncludesPairing;
        _applicationSnapshotIncludesPairing = false;
      }
    });
  }

  Future<ApplicationSnapshot> _buildApplicationSnapshot({
    bool includePairing = false,
  }) async {
    // Production bridges implement the atomic typed projection. Keep a
    // narrow compatibility path for test/developer runtimes that predate the
    // method; it is never used by Android or Windows production bridges.
    final snapshot = _runtime is RuntimeProjectionProvider
        ? await (_runtime as RuntimeProjectionProvider).applicationSnapshot()
        : await _legacyApplicationSnapshotForUnsupportedRuntime();
    if (snapshot == null) {
      throw StateError('Runtime returned no application projection');
    }
    if (!includePairing) {
      applicationState.hydrate(snapshot);
      return snapshot;
    }

    final pairing = await _loadPairingBatch(force: true);
    final enriched = snapshot.copyWith(
      pendingInbox: pairing.inbox.length,
      pendingOutbox: pairing.outbox.length,
    );
    applicationState.hydrate(enriched);
    return enriched;
  }

  Future<ApplicationSnapshot?>
  _legacyApplicationSnapshotForUnsupportedRuntime() async {
    final values = await Future.wait<Object?>([
      _runtime.identity(),
      _runtime.profile(),
      _runtime.contacts(),
      _runtime.conversations(),
      _runtime.peerEndpointAvailable(),
      _runtime.startupReadiness(),
    ]);
    final identity = values[0] as RuntimeIdentity? ?? const RuntimeIdentity();
    final profile = values[1] as RuntimeProfile? ?? const RuntimeProfile();
    final contacts = values[2] as List<ContactRecord>;
    final conversations = values[3] as List<ConversationSummary>;
    final peerEndpointAvailable = values[4] as bool;
    final generation = (values[5] as StartupReadinessSnapshot).generation;
    return ApplicationSnapshot(
      generation: generation,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      identity: identity,
      profile: profile,
      contacts: contacts,
      conversations: conversations,
      peerEndpointAvailable: peerEndpointAvailable,
    );
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
    // Start both authoritative reads before awaiting either one. Pairing is
    // deliberately returned in this value object instead of being read back
    // from `_latestPairingSnapshot` after completion; an incoming event may
    // invalidate that cache between the fetch and controller publication.
    final projectionFuture = applicationSnapshot(force: true);
    final pairingFuture = includePairing
        ? _loadPairingBatch(force: true)
        : Future<RuntimePairingSnapshot?>.value(null);
    final projection = await projectionFuture;
    final pairing = await pairingFuture;
    final application = pairing == null
        ? projection
        : projection.copyWith(
            pendingInbox: pairing.inbox.length,
            pendingOutbox: pairing.outbox.length,
          );
    if (!identical(application, projection)) {
      applicationState.hydrate(application);
    }
    final local = RuntimeLocalSnapshot(
      contacts: application.contacts,
      conversations: application.conversations,
      peerEndpointAvailable: application.peerEndpointAvailable,
      generation: application.generation,
    );
    return RuntimeRefreshSnapshot(
      application: application,
      local: local,
      pairing: pairing,
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
    if (current != null) {
      if (force) {
        return current.then((_) => _loadLocalBatch(force: true));
      }
      return current;
    }
    final invalidationEpoch = _localInvalidationEpoch;
    final generation = _nextGeneration();
    final request =
        Future.wait<Object>([
          _runtime.contacts(),
          _runtime.conversations(),
          _runtime.peerEndpointAvailable(),
        ]).then((values) {
          final snapshot = RuntimeLocalSnapshot(
            contacts: List.unmodifiable(
              (values[0] as List<ContactRecord>).map(_applyLivePeerStatus),
            ),
            conversations: List.unmodifiable(
              values[1] as List<ConversationSummary>,
            ),
            peerEndpointAvailable: values[2] as bool,
            generation: generation,
          );
          if (invalidationEpoch == _localInvalidationEpoch) {
            _latestLocalSnapshot = snapshot;
            _localCacheTime = DateTime.now();
          }
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
    final request =
        Future.wait<Object>([
          _runtime.pairingInbox(),
          _runtime.pairingOutbox(),
        ]).then((values) {
          final snapshot = RuntimePairingSnapshot(
            inbox: List.unmodifiable(values[0] as List<PairingItem>),
            outbox: List.unmodifiable(values[1] as List<PairingItem>),
            generation: generation,
          );
          _latestPairingSnapshot = snapshot;
          ApplicationStateStore.shared.setPairing(
            snapshot.inbox,
            snapshot.outbox,
          );
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
    _localInvalidationEpoch += 1;
    _localCacheTime = null;
    _latestLocalSnapshot = null;
    _cachedApplicationSnapshotIncludesPairing = false;
    if (markSnapshotStale) applicationState.markStale();
  }

  void invalidatePairingCache({bool markSnapshotStale = true}) {
    _pairingCacheTime = null;
    _latestPairingSnapshot = null;
    _cachedApplicationSnapshotIncludesPairing = false;
    if (markSnapshotStale) applicationState.markStale();
  }

  ContactRecord _applyLivePeerStatus(ContactRecord contact) {
    final status = _livePeerStatuses[contact.id];
    return status == null
        ? contact
        : contact.copyWith(peerConnectionStatus: status);
  }

  void _refreshApplicationSnapshotInBackground({bool includePairing = false}) {
    unawaited(
      applicationSnapshot(
        includePairing: includePairing,
        force: true,
      ).then<void>((_) {}).catchError((Object _, StackTrace _) {}),
    );
  }

  void _warmPairingCache() {
    unawaited(
      _loadPairingBatch()
          .then<void>((_) {
            _refreshApplicationSnapshotInBackground(includePairing: true);
          })
          .catchError((Object _, StackTrace _) {}),
    );
  }

  Future<PairingItem> submitPairingCode(String code) async {
    final item = await _runtime.submitPairingCode(code);
    invalidatePairingCache();
    return item;
  }

  Future<void> acceptPairing(String id) async {
    await _runtime.acceptPairing(id);
    invalidatePairingCache();
    invalidateLocalCache();
  }

  Future<void> rejectPairing(String id) async {
    await _runtime.rejectPairing(id);
    invalidatePairingCache();
  }

  Future<void> archiveInvite(String id) async {
    await _runtime.archivePairing(id);
    invalidatePairingCache();
  }

  Future<void> cancelPairing(String id) async {
    await _runtime.cancelPairing(id);
    invalidatePairingCache();
  }

  Future<void> verifyContact(String id) async {
    await _runtime.verifyContact(id);
    invalidateLocalCache();
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
    return contact;
  }

  Future<void> removeRelationship(
    String id, {
    required bool preserveHistory,
  }) async {
    await _runtime.removeRelationship(id, preserveHistory: preserveHistory);
    invalidateLocalCache();
  }

  Future<List<ContactRecord>> contacts() async =>
      (await _loadLocalBatch()).contacts;

  Future<List<ConversationSummary>> conversations() async =>
      (await _loadLocalBatch()).conversations;

  /// Refreshes the conversation summary after a message mutation without
  /// touching the message projection itself. The caller is responsible for
  /// loading messages with `force: true` so the two projections cannot race.
  Future<void> refreshDataForConversation(String conversationId) async {
    if (conversationId.trim().isEmpty) return;
    invalidateLocalCache();
    await applicationSnapshot(force: true);
  }

  Future<List<ChatMessage>> messages(String id, {bool force = false}) {
    if (!force) {
      final cached = _messageCache.remove(id);
      if (cached != null) {
        _messageCache[id] = cached;
        return Future.value(cached);
      }
    }
    final current = _messagesInFlight[id];
    if (current != null) {
      if (force) {
        // Collapse all invalidations arriving during an active projection
        // fetch into one trailing fetch. A single delivery emits several ACK
        // and projection events; chaining one request per event caused a
        // refresh convoy over the open conversation.
        _messageTrailingRefreshRequested.add(id);
        return current.then((_) {
          if (_messageTrailingRefreshRequested.remove(id)) {
            return messages(id, force: true);
          }
          return applicationState.messages(id);
        });
      }
      return current;
    }

    _messageLoadController.add(
      ConversationMessagesLoadState(
        conversationId: id,
        phase: ConversationMessagesPhase.loading,
      ),
    );
    final sequence = (_messageRequestSequence[id] ?? 0) + 1;
    _messageRequestSequence[id] = sequence;
    final request = _loadMessages(
      id,
      _messageInvalidationEpoch[id] ?? 0,
      sequence,
    );
    _messagesInFlight[id] = request;
    return request.whenComplete(() {
      if (identical(_messagesInFlight[id], request)) {
        _messagesInFlight.remove(id);
      }
    });
  }

  Future<List<ChatMessage>> _loadMessages(
    String id,
    int invalidationEpoch,
    int requestSequence,
  ) async {
    try {
      // The bare `messages(id)` operation is intentionally a bounded page
      // (currently 50 rows).  The live conversation projection must never
      // treat that page as the complete history: a status event could then
      // replace an already hydrated conversation with only its newest rows.
      // Use the explicit full-history operation here; paging is reserved for
      // the user-driven history loader.
      final messages = await _runtime.allMessages(id);
      final projection = List<ChatMessage>.unmodifiable(messages);
      final currentEpoch = _messageInvalidationEpoch[id] ?? 0;
      final appliedSequence = _messageAppliedSequence[id] ?? 0;
      if (invalidationEpoch == currentEpoch &&
          requestSequence > appliedSequence) {
        // The full-history projection must replace the previous projection.
        // Merging here could resurrect rows deleted by a
        // relationship reset and could make an old cache look newer than the
        // database. Overlapping responses are ordered by request sequence;
        // only the newest response for the current invalidation epoch wins.
        applicationState.replaceMessages(id, projection);
        _messageAppliedSequence[id] = requestSequence;
        _messageCache[id] = projection;
      }
      while (_messageCache.length > _messageCacheLimit) {
        _messageCache.remove(_messageCache.keys.first);
      }
      _messageLoadController.add(
        ConversationMessagesLoadState(
          conversationId: id,
          phase: ConversationMessagesPhase.ready,
        ),
      );
      return applicationState.messages(id);
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
      _messageTrailingRefreshRequested.addAll(_messagesInFlight.keys);
      for (final id in _messagesInFlight.keys) {
        _messageInvalidationEpoch[id] =
            (_messageInvalidationEpoch[id] ?? 0) + 1;
      }
      return;
    }
    _messageInvalidationEpoch[conversationId] =
        (_messageInvalidationEpoch[conversationId] ?? 0) + 1;
    if (_messagesInFlight.containsKey(conversationId)) {
      _messageTrailingRefreshRequested.add(conversationId);
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
  }

  Future<void> rotatePeerEndpoint() async {
    await _runtime.rotatePeerEndpoint();
    invalidateLocalCache();
  }

  Future<void> openConversation(String id) async {
    await _runtime.openConversation(id);
    invalidateLocalCache();
  }

  Future<void> closeConversation() => _runtime.closeConversation();

  Future<void> startConversation(String id) async {
    await _runtime.startConversation(id);
    invalidateLocalCache();
  }

  /// The sole client-side entry point for making a conversation usable.
  Future<ActivatedConversation> activateConversation(String contactId) async {
    var snapshot = await applicationSnapshot(force: true);
    var conversation = snapshot.conversations.firstOrNullWhere(
      (item) => item.contactId == contactId || item.id == contactId,
    );
    if (conversation == null) {
      await _runtime.startConversation(contactId);
      invalidateLocalCache();
      snapshot = await applicationSnapshot(force: true);
      conversation = snapshot.conversations.firstOrNullWhere(
        (item) => item.contactId == contactId || item.id == contactId,
      );
    }
    if (conversation == null) {
      throw StateError(
        'Runtime did not materialize a conversation for contact $contactId',
      );
    }

    await _runtime.openConversation(conversation.id);
    invalidateLocalCache();
    invalidateMessages(conversation.id);
    final initialMessages = await messages(conversation.id, force: true);
    await applicationSnapshot(force: true);
    return ActivatedConversation(
      conversation: conversation,
      messages: initialMessages,
    );
  }

  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {
    await _runtime.sendMessage(id, text, replyToMessageId: replyToMessageId);
    invalidateMessages(id);
    invalidateLocalCache();
  }

  Future<void> retryMessage(String messageId) async {
    await _runtime.retryMessage(messageId);
    invalidateMessages();
    invalidateLocalCache();
  }

  Future<void> deleteMessageLocal(String messageId) async {
    await _runtime.deleteMessageLocal(messageId);
    final conversationId = applicationState.removeMessage(messageId);
    if (conversationId == null) {
      invalidateMessages();
    } else {
      _messageCache.remove(conversationId);
      invalidateMessages(conversationId);
    }
    invalidateLocalCache();
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
