import '../../client_runtime.dart';

class RuntimeRepository {
  RuntimeRepository(this._runtime);
  final ClientRuntime _runtime;

  Stream<RuntimeEvent> get events => _runtime.events;

  Future<bool> connect() => _runtime.connect();
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
  Future<List<ContactRecord>> contacts() async => await _runtime.contacts();
  Future<List<ConversationSummary>> conversations() async =>
      await _runtime.conversations();
  Future<List<ChatMessage>> messages(String id) async =>
      await _runtime.messages(id);
  Future<List<PairingItem>> inbox() async => await _runtime.pairingInbox();
  Future<List<PairingItem>> outbox() async => await _runtime.pairingOutbox();
  Future<PeerEndpoint?> peerEndpoint() => _runtime.peerEndpoint();
  Future<bool> peerEndpointAvailable() => _runtime.peerEndpointAvailable();
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

  Future<void> setTyping(String conversationId, bool typing) =>
      _runtime.setTyping(conversationId, typing);

  Future<void> setPresence(bool online) => _runtime.setPresence(online);

  Future<void> sendReadReceipts(String conversationId) =>
      _runtime.sendReadReceipts(conversationId);

  Future<void> updateAppVisibility(bool foreground) =>
      _runtime.updateAppVisibility(foreground);
}
