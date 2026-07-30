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

  Future<List<ContactRecord>>? _contactsInFlight;
  Future<List<ConversationSummary>>? _conversationsInFlight;
  Future<List<PairingItem>>? _inboxInFlight;
  Future<List<PairingItem>>? _outboxInFlight;
  Future<bool>? _peerEndpointAvailableInFlight;
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;
  RuntimeLocalSnapshot? _latestLocalSnapshot;
  RuntimePairingSnapshot? _latestPairingSnapshot;
  DateTime? _pairingCacheTime;

  Stream<RuntimeEvent> get events => _runtime.events;

  Future<bool> connect() async {
    final connected = await _runtime.connect();
    _lastTyping.clear();
    _lastPresence = null;
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
      local: (generation) async {
        final values = await Future.wait<Object>([
          contacts(),
          conversations(),
          peerEndpointAvailable(),
        ]);
        _latestLocalSnapshot = RuntimeLocalSnapshot(
          contacts: values[0] as List<ContactRecord>,
          conversations: values[1] as List<ConversationSummary>,
          peerEndpointAvailable: values[2] as bool,
          generation: generation,
        );
      },
      remote: (generation) async {
        final values = await Future.wait<Object>([
          inbox(force: true),
          outbox(force: true),
        ]);
        _latestPairingSnapshot = RuntimePairingSnapshot(
          inbox: values[0] as List<PairingItem>,
          outbox: values[1] as List<PairingItem>,
          generation: generation,
        );
        _pairingCacheTime = DateTime.now();
      },
    );
    final local = _latestLocalSnapshot;
    if (local == null) throw StateError('Local runtime refresh produced no snapshot');
    return RuntimeRefreshSnapshot(
      local: local,
      pairing: includePairing ? _latestPairingSnapshot : null,
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

  void invalidatePairingCache() {
    _pairingCacheTime = null;
    _latestPairingSnapshot = null;
  }

  Future<void> verifyContact(String id) => _runtime.verifyContact(id);
  Future<ContactRecord> updateContactSettings(
    String id, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) => _runtime.updateContactSettings(
    id,
    localAlias: localAlias,
    muted: muted,
    blocked: blocked,
    transportPolicy: transportPolicy,
  );

  Future<List<ContactRecord>> contacts() {
    final current = _contactsInFlight;
    if (current != null) return current;
    final request = _runtime.contacts();
    _contactsInFlight = request;
    return request.whenComplete(() {
      if (identical(_contactsInFlight, request)) _contactsInFlight = null;
    });
  }

  Future<List<ConversationSummary>> conversations() {
    final current = _conversationsInFlight;
    if (current != null) return current;
    final request = _runtime.conversations();
    _conversationsInFlight = request;
    return request.whenComplete(() {
      if (identical(_conversationsInFlight, request)) {
        _conversationsInFlight = null;
      }
    });
  }

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

  bool get _pairingCacheFresh {
    final time = _pairingCacheTime;
    return time != null && DateTime.now().difference(time) < const Duration(seconds: 5);
  }

  Future<List<PairingItem>> inbox({bool force = false}) {
    if (!force && _pairingCacheFresh && _latestPairingSnapshot != null) {
      return Future.value(_latestPairingSnapshot!.inbox);
    }
    final current = _inboxInFlight;
    if (current != null) return current;
    final request = _runtime.pairingInbox();
    _inboxInFlight = request;
    return request.whenComplete(() {
      if (identical(_inboxInFlight, request)) _inboxInFlight = null;
    });
  }

  Future<List<PairingItem>> outbox({bool force = false}) {
    if (!force && _pairingCacheFresh && _latestPairingSnapshot != null) {
      return Future.value(_latestPairingSnapshot!.outbox);
    }
    final current = _outboxInFlight;
    if (current != null) return current;
    final request = _runtime.pairingOutbox();
    _outboxInFlight = request;
    return request.whenComplete(() {
      if (identical(_outboxInFlight, request)) _outboxInFlight = null;
    });
  }

  Future<PeerEndpoint?> peerEndpoint() => _runtime.peerEndpoint();

  Future<bool> peerEndpointAvailable() {
    final current = _peerEndpointAvailableInFlight;
    if (current != null) return current;
    final request = _runtime.peerEndpointAvailable();
    _peerEndpointAvailableInFlight = request;
    return request.whenComplete(() {
      if (identical(_peerEndpointAvailableInFlight, request)) {
        _peerEndpointAvailableInFlight = null;
      }
    });
  }

  Future<void> retryPeerConnection(String installationId) =>
      _runtime.retryPeerConnection(installationId);
  Future<void> rotatePeerEndpoint() => _runtime.rotatePeerEndpoint();
  Future<void> openConversation(String id) => _runtime.openConversation(id);
  Future<void> closeConversation() => _runtime.closeConversation();
  Future<void> startConversation(String id) => _runtime.startConversation(id);
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => _runtime.sendMessage(id, text, replyToMessageId: replyToMessageId);

  Future<void> retryMessage(String messageId) =>
      _runtime.retryMessage(messageId);

  Future<void> deleteMessageLocal(String messageId) =>
      _runtime.deleteMessageLocal(messageId);

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
