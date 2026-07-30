import '../../client_runtime.dart';
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

class RuntimeRepository {
  RuntimeRepository(this._runtime);
  final ClientRuntime _runtime;
  final RefreshCoordinator _refreshCoordinator = RefreshCoordinator();

  Future<RuntimeLocalSnapshot>? _localBatchInFlight;
  Future<RuntimePairingSnapshot>? _pairingBatchInFlight;
  RuntimeLocalSnapshot? _latestLocalSnapshot;
  RuntimePairingSnapshot? _latestPairingSnapshot;
  DateTime? _localCacheTime;
  DateTime? _pairingCacheTime;
  int _snapshotGeneration = 0;
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;

  Stream<RuntimeEvent> get events => _runtime.events;

  Future<bool> connect() async {
    final connected = await _runtime.connect();
    _lastTyping.clear();
    _lastPresence = null;
    invalidateLocalCache();
    return connected;
  }

  Future<RuntimeIdentity> identity() async =>
      await _runtime.identity() ?? const RuntimeIdentity();
  Future<RuntimeProfile> profile() async =>
      await _runtime.profile() ?? const RuntimeProfile();
  Future<RuntimeProfile> setNickname(String value) async =>
      await _runtime.setNickname(value);
  Future<InviteCode?> refreshInviteCode() => _runtime.refreshPairingCode();

  Future<RuntimeRefreshSnapshot> refresh({bool includePairing = false}) async {
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
    if (local == null) throw StateError('Local runtime refresh produced no snapshot');
    return RuntimeRefreshSnapshot(
      local: local,
      pairing: includePairing ? _latestPairingSnapshot : null,
    );
  }

  bool get _localCacheFresh {
    final time = _localCacheTime;
    return time != null &&
        DateTime.now().difference(time) < const Duration(milliseconds: 350);
  }

  bool get _pairingCacheFresh {
    final time = _pairingCacheTime;
    return time != null &&
        DateTime.now().difference(time) < const Duration(seconds: 5);
  }

  Future<RuntimeLocalSnapshot> _loadLocalBatch({bool force = false}) {
    if (!force && _localCacheFresh && _latestLocalSnapshot != null) {
      return Future.value(_latestLocalSnapshot!);
    }
    final current = _localBatchInFlight;
    if (current != null) return current;
    final generation = ++_snapshotGeneration;
    final request = Future.wait<Object>([
      _runtime.contacts(),
      _runtime.conversations(),
      _runtime.peerEndpointAvailable(),
    ]).then((values) {
      final snapshot = RuntimeLocalSnapshot(
        contacts: values[0] as List<ContactRecord>,
        conversations: values[1] as List<ConversationSummary>,
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
    final generation = ++_snapshotGeneration;
    final request = Future.wait<Object>([
      _runtime.pairingInbox(),
      _runtime.pairingOutbox(),
    ]).then((values) {
      final snapshot = RuntimePairingSnapshot(
        inbox: values[0] as List<PairingItem>,
        outbox: values[1] as List<PairingItem>,
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

  void invalidateLocalCache() {
    _localCacheTime = null;
    _latestLocalSnapshot = null;
  }

  void invalidatePairingCache() {
    _pairingCacheTime = null;
    _latestPairingSnapshot = null;
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

  Future<List<ContactRecord>> contacts() async =>
      (await _loadLocalBatch()).contacts;

  Future<List<ConversationSummary>> conversations() async =>
      (await _loadLocalBatch()).conversations;

  Future<List<ChatMessage>> messages(String id) {
    final current = _messagesInFlight[id];
    if (current != null) return current;
    final request = _runtime.messages(id);
    _messagesInFlight[id] = request;
    return request.whenComplete(() {
      if (identical(_messagesInFlight[id], request)) {
        _messagesInFlight.remove(id);
      }
    });
  }

  Future<List<PairingItem>> inbox({bool force = false}) async =>
      (await _loadPairingBatch(force: force)).inbox;

  Future<List<PairingItem>> outbox({bool force = false}) async =>
      (await _loadPairingBatch(force: force)).outbox;

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

  Future<void> openConversation(String id) => _runtime.openConversation(id);
  Future<void> closeConversation() => _runtime.closeConversation();

  Future<void> startConversation(String id) async {
    await _runtime.startConversation(id);
    invalidateLocalCache();
  }

  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {
    await _runtime.sendMessage(id, text, replyToMessageId: replyToMessageId);
    invalidateLocalCache();
  }

  Future<void> retryMessage(String messageId) async {
    await _runtime.retryMessage(messageId);
    invalidateLocalCache();
  }

  Future<void> deleteMessageLocal(String messageId) async {
    await _runtime.deleteMessageLocal(messageId);
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
