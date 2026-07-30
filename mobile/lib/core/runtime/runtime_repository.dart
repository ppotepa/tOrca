import 'dart:async';

import '../../client_runtime.dart';

class RuntimeRepository {
  RuntimeRepository(this._runtime);
  final ClientRuntime _runtime;

  Future<List<ContactRecord>>? _contactsInFlight;
  Future<List<ConversationSummary>>? _conversationsInFlight;
  Future<List<PairingItem>>? _inboxInFlight;
  Future<List<PairingItem>>? _outboxInFlight;
  Future<bool>? _peerEndpointAvailableInFlight;
  final Map<String, Future<List<ChatMessage>>> _messagesInFlight = {};
  final Map<String, bool> _lastTyping = {};
  bool? _lastPresence;
  Future<bool>? _connectionInFlight;

  Stream<RuntimeEvent> get events => _runtime.events;

  Future<bool> connect() async {
    // Android's foreground service owns the potentially slow Tor/onion relay
    // bootstrap. Starting the Flutter UI must not wait for that remote route:
    // all local queries below already wait for the engine's localReady barrier.
    // Keep one background connect request in flight and let transport events
    // report progress, reconnects and failures to the UI.
    final current = _connectionInFlight;
    if (current == null) {
      final request = _runtime.connect();
      _connectionInFlight = request;
      unawaited(
        request.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ).whenComplete(() {
          if (identical(_connectionInFlight, request)) {
            _connectionInFlight = null;
          }
        }),
      );
    }

    // A new transport generation must be allowed to publish the latest
    // ephemeral state again even when the UI value did not change.
    _lastTyping.clear();
    _lastPresence = null;
    return true;
  }

  Future<RuntimeIdentity> identity() async =>
      await _runtime.identity() ?? const RuntimeIdentity();
  Future<RuntimeProfile> profile() async =>
      await _runtime.profile() ?? const RuntimeProfile();
  Future<RuntimeProfile> setNickname(String value) async =>
      await _runtime.setNickname(value);
  Future<InviteCode?> refreshInviteCode() async {
    return _runtime.refreshPairingCode();
  }

  Future<PairingItem> submitPairingCode(String code) async =>
      await _runtime.submitPairingCode(code);
  Future<void> acceptPairing(String id) => _runtime.acceptPairing(id);

  Future<void> rejectPairing(String id) => _runtime.rejectPairing(id);

  Future<void> archiveInvite(String id) => _runtime.archivePairing(id);

  Future<void> cancelPairing(String id) => _runtime.cancelPairing(id);

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

  Future<List<PairingItem>> inbox() {
    final current = _inboxInFlight;
    if (current != null) return current;
    final request = _runtime.pairingInbox();
    _inboxInFlight = request;
    return request.whenComplete(() {
      if (identical(_inboxInFlight, request)) _inboxInFlight = null;
    });
  }

  Future<List<PairingItem>> outbox() {
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
