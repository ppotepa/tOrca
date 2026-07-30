import 'windows_runtime.dart';
export 'core/models/domain.dart';
import 'core/models/domain.dart';

/// Platform-neutral contract consumed by the Flutter UI.
abstract interface class ClientRuntime {
  Stream<RuntimeEvent> get events;
  Future<bool> connect();
  Future<RuntimeIdentity?> identity();
  Future<RuntimeProfile?> profile();
  Future<InviteCode?> refreshPairingCode();
  Future<RuntimeProfile> setNickname(String nickname);
  Future<PairingItem> submitPairingCode(String code);
  Future<List<PairingItem>> pairingInbox();
  Future<List<PairingItem>> pairingOutbox();
  Future<PeerEndpoint?> peerEndpoint();
  Future<bool> peerEndpointAvailable();
  Future<void> retryPeerConnection(String installationId);
  Future<void> rotatePeerEndpoint();
  Future<void> verifyContact(String installationId);
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  });
  Future<List<ContactRecord>> contacts();
  Future<List<ConversationSummary>> conversations();
  Future<List<ChatMessage>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> closeConversation();
  Future<void> startConversation(String contactId);
  Future<void> sendMessage(String id, String text, {String? replyToMessageId});
  Future<void> retryMessage(String messageId) async {}
  Future<void> deleteMessageLocal(String messageId) async {}
  Future<void> setTyping(String conversationId, bool typing) async {}
  Future<void> setPresence(bool online) async {}
  Future<void> sendReadReceipts(String conversationId) async {}
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> cancelPairing(String pairingId);
  Future<void> archivePairing(String pairingId);
  Future<void> updateAppVisibility(bool foreground);
}

ClientRuntime createClientRuntime() => createPlatformRuntime();
