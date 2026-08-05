import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import '../../client_runtime.dart';
import '../application_state/application_snapshot.dart';
import '../application_state/application_state_store.dart';
import 'message_paging.dart';
import 'message_projection.dart';
import 'runtime_repository_models.dart';

export 'runtime_repository_models.dart';

class RuntimeRepository {
  RuntimeRepository(this._runtime);

  static const int _messageCacheLimit = 5;

  final ClientRuntime _runtime;
  final ApplicationStateStore applicationState = ApplicationStateStore.shared;

  ApplicationSnapshot? get currentApplicationSnapshot =>
      applicationState.current;

  RuntimePairingSnapshot? get currentPairingSnapshot {
    final snapshot = applicationState.current;
    return snapshot == null ? null : _pairingProjection(snapshot);
  }

  final LinkedHashMap<String, List<ChatMessage>> _messageCache =
      LinkedHashMap<String, List<ChatMessage>>();
  final StreamController<ConversationMessagesLoadState> _messageLoadController =
      StreamController<ConversationMessagesLoadState>.broadcast(sync: true);

  Future<RuntimeLocalSnapshot>? _localBatchInFlight;
  Future<ApplicationSnapshot>? _applicationSnapshotInFlight;
  bool _applicationTrailingRefreshRequested = false;
  RuntimeLocalSnapshot? _latestLocalSnapshot;
  DateTime? _localCacheTime;
  int _snapshotGeneration = 0;
  int _localInvalidationEpoch = 0;
  int _applicationInvalidationEpoch = 0;
  final Map<String, int> _messageInvalidationEpoch = <String, int>{};
  final Map<String, int> _messageRequestSequence = <String, int>{};
  final Map<String, int> _messageAppliedSequence = <String, int>{};
  final Map<String, PeerConnectionStatus> _livePeerStatuses =
      <String, PeerConnectionStatus>{};
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Set<String> _messageTrailingRefreshRequested = <String>{};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;

  Future<void> dispose() async {
    await _messageLoadController.close();
    if (_runtime case final RuntimeDisposable runtime) {
      await runtime.disposeRuntime();
    }
  }

  // Runtime events have exactly one consumer-side coordinator. Cache
  // invalidation and projection refresh are owned by the application
  // controller; performing them here as well creates competing refreshes.
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

  Future<RuntimeProfile> profile({bool force = false}) async {
    if (!force) {
      final projected = applicationState.current?.profile;
      if (projected != null) return projected;
    }
    return await _runtime.profile() ?? const RuntimeProfile();
  }

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
    final merged = <ChatMessage>[...added, ...current]..sort(compareMessages);
    applicationState.mergeMessages(conversationId, merged);
    _messageCache[conversationId] = List<ChatMessage>.unmodifiable(merged);
    return added.length;
  }

  Future<RuntimeProfile> setNickname(String value) async {
    final profile = await _runtime.setNickname(value);
    _invalidateApplicationProjection();
    await applicationSnapshot(force: true);
    return profile;
  }

  Future<InviteCode?> refreshInviteCode() => _runtime.refreshPairingCode();

  Future<ApplicationSnapshot> applicationSnapshot({
    bool includePairing = false,
    bool force = false,
  }) {
    final cached = applicationState.current;
    final requiresSchemaTwo = includePairing;
    if (!force &&
        cached != null &&
        !applicationState.isStale &&
        (!requiresSchemaTwo || cached.schemaVersion >= 2)) {
      return Future.value(cached);
    }

    final inFlight = _applicationSnapshotInFlight;
    if (inFlight != null) {
      if (force) {
        _applicationTrailingRefreshRequested = true;
        return inFlight.then((snapshot) {
          if (!_applicationTrailingRefreshRequested) return snapshot;
          _applicationTrailingRefreshRequested = false;
          return applicationSnapshot(
            includePairing: includePairing,
            force: true,
          );
        });
      }
      return inFlight;
    }

    final request = _buildApplicationSnapshot();
    _applicationSnapshotInFlight = request;
    return request.whenComplete(() {
      if (identical(_applicationSnapshotInFlight, request)) {
        _applicationSnapshotInFlight = null;
      }
    });
  }

  Future<ApplicationSnapshot> _buildApplicationSnapshot() async {
    final applicationEpoch = _applicationInvalidationEpoch;
    var snapshot = _runtime is RuntimeProjectionProvider
        ? await (_runtime as RuntimeProjectionProvider).applicationSnapshot()
        : null;
    if (snapshot == null) {
      final values = await Future.wait<Object?>([
        _runtime.identity(),
        _runtime.profile(),
        _loadLocalBatch(force: true),
        _runtime.listPairings(),
      ]);
      final local = values[2] as RuntimeLocalSnapshot;
      final pairings = values[3] as List<PairingItem>;
      final inbox = <PairingItem>[];
      final outbox = <PairingItem>[];
      for (final item in pairings) {
        switch (item.origin) {
          case PairingOrigin.inbox:
            inbox.add(item);
          case PairingOrigin.outbox:
            outbox.add(item);
          case PairingOrigin.unknown:
            (item.received ? inbox : outbox).add(item);
        }
      }
      snapshot = ApplicationSnapshot(
        schemaVersion: 2,
        generation: local.generation,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        identity: values[0] as RuntimeIdentity? ?? const RuntimeIdentity(),
        profile: values[1] as RuntimeProfile? ?? const RuntimeProfile(),
        contacts: local.contacts,
        conversations: local.conversations,
        pairingInbox: List<PairingItem>.unmodifiable(inbox),
        pairingOutbox: List<PairingItem>.unmodifiable(outbox),
        pendingInbox: inbox.where((item) => item.status.isOutstanding).length,
        pendingOutbox: outbox.where((item) => item.status.isOutstanding).length,
        peerEndpointAvailable: local.peerEndpointAvailable,
      );
    }
    if (applicationEpoch != _applicationInvalidationEpoch) {
      return _buildApplicationSnapshot();
    }
    applicationState.hydrate(snapshot);
    return applicationState.current ?? snapshot;
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
    final application = await applicationSnapshot(
      includePairing: includePairing,
      force: true,
    );
    final local = RuntimeLocalSnapshot(
      contacts: application.contacts,
      conversations: application.conversations,
      peerEndpointAvailable: application.peerEndpointAvailable,
      generation: application.generation,
    );
    return RuntimeRefreshSnapshot(
      application: application,
      local: local,
      pairing: includePairing ? _pairingProjection(application) : null,
    );
  }

  RuntimePairingSnapshot _pairingProjection(ApplicationSnapshot snapshot) =>
      RuntimePairingSnapshot(
        inbox: snapshot.pairingInbox,
        outbox: snapshot.pairingOutbox,
        generation: snapshot.generation,
      );

  bool get _localCacheFresh {
    final time = _localCacheTime;
    return time != null &&
        DateTime.now().difference(time) < const Duration(seconds: 2);
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

  void invalidateLocalCache({bool markSnapshotStale = true}) {
    _localInvalidationEpoch += 1;
    _localCacheTime = null;
    _latestLocalSnapshot = null;
    _invalidateApplicationProjection(markSnapshotStale: markSnapshotStale);
  }

  void _invalidateApplicationProjection({bool markSnapshotStale = true}) {
    _applicationInvalidationEpoch += 1;
    if (markSnapshotStale) applicationState.markStale();
  }

  ContactRecord _applyLivePeerStatus(ContactRecord contact) {
    final status = _livePeerStatuses[contact.id];
    return status == null
        ? contact
        : contact.copyWith(peerConnectionStatus: status);
  }

  void _refreshApplicationSnapshotInBackground() {
    unawaited(
      applicationSnapshot(force: true)
          .then<void>((_) {})
          .catchError((Object _, StackTrace _) {}),
    );
  }

  Future<PairingItem> submitPairingCode(String code) async {
    final item = await _runtime.submitPairingCode(code);
    _invalidateApplicationProjection();
    return item;
  }

  /// Pairing, contacts and conversations are one authoritative projection.
  Future<RuntimeRefreshSnapshot> refreshPairingAndApplication() async {
    invalidateLocalCache();
    return refresh(includePairing: true, bypassCooldown: true);
  }

  Future<void> acceptPairing(String id) async {
    await _runtime.acceptPairing(id);
    invalidateLocalCache();
  }

  Future<void> rejectPairing(String id) async {
    await _runtime.rejectPairing(id);
    _invalidateApplicationProjection();
  }

  Future<void> archiveInvite(String id) async {
    await _runtime.archivePairing(id);
    _invalidateApplicationProjection();
  }

  Future<void> cancelPairing(String id) async {
    await _runtime.cancelPairing(id);
    _invalidateApplicationProjection();
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
      // (currently 50 rows). The live conversation projection must never
      // treat that page as the complete history. Use the explicit full-history
      // operation here; paging remains user driven.
      final messages = await _runtime.allMessages(id);
      final projection = List<ChatMessage>.unmodifiable(messages);
      final currentEpoch = _messageInvalidationEpoch[id] ?? 0;
      final appliedSequence = _messageAppliedSequence[id] ?? 0;
      developer.log(
        'message projection fetched count=${projection.length} '
        'epoch=$invalidationEpoch currentEpoch=$currentEpoch '
        'sequence=$requestSequence appliedSequence=$appliedSequence',
        name: 'torchat.projection',
      );
      if (invalidationEpoch == currentEpoch &&
          requestSequence > appliedSequence) {
        final merged = applicationState.mergeMessages(id, projection);
        _messageAppliedSequence[id] = requestSequence;
        _messageCache[id] = merged;
        developer.log(
          'message projection applied count=${merged.length} '
          'sequence=$requestSequence',
          name: 'torchat.projection',
        );
      } else {
        developer.log(
          'message projection discarded count=${projection.length}',
          name: 'torchat.projection',
        );
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
    final current = applicationState.current;
    if (!force && current != null && current.schemaVersion >= 2) {
      return current.pairingInbox;
    }
    return (await applicationSnapshot(includePairing: true, force: true))
        .pairingInbox;
  }

  Future<List<PairingItem>> outbox({bool force = false}) async {
    final current = applicationState.current;
    if (!force && current != null && current.schemaVersion >= 2) {
      return current.pairingOutbox;
    }
    return (await applicationSnapshot(includePairing: true, force: true))
        .pairingOutbox;
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
    // Apply the durable queued message immediately. Transport events may
    // arrive before or after the command response, so the repository owns
    // this one read-your-writes refresh and the controller does not start a
    // second competing request.
    invalidateMessages(id);
    await messages(id, force: true);
    await refreshDataForConversation(id);
  }

  Future<void> retryMessage(String messageId) async {
    await _runtime.retryMessage(messageId);
    invalidateMessages();
    invalidateLocalCache();
  }

  Future<void> retryDeadLetter(String kind, String id) async {
    await _runtime.retryDeadLetter(kind, id);
    invalidateLocalCache();
  }

  Future<List<Map<String, dynamic>>> listDeadLetters() async =>
      await (_runtime as dynamic).listDeadLetters()
          as List<Map<String, dynamic>>;

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

  Future<ReadReceiptQueueResult?> setConversationFocus(
    String conversationId,
    bool focused,
  ) async {
    try {
      await (_runtime as dynamic).setConversationFocus(conversationId, focused);
      if (focused && conversationId.isNotEmpty) {
        return queueReadReceipts(conversationId);
      }
    } catch (_) {
      // Focus is transient. The heartbeat will repair a dropped update.
    }
    return null;
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

  Future<ReadReceiptQueueResult> queueReadReceipts(
    String conversationId,
  ) async {
    try {
      await _runtime.sendReadReceipts(conversationId);
      return const ReadReceiptQueueResult(ReadReceiptQueueStatus.queued);
    } on UnsupportedError {
      return const ReadReceiptQueueResult(ReadReceiptQueueStatus.disabled);
    } catch (error) {
      return ReadReceiptQueueResult(
        ReadReceiptQueueStatus.error,
        error: error.toString(),
      );
    }
  }

  Future<void> updateAppVisibility(bool foreground) =>
      _runtime.updateAppVisibility(foreground);
}
