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
  Future<void> verifyContact(String installationId);
  Future<List<ContactRecord>> contacts();
  Future<List<ConversationSummary>> conversations();
  Future<List<ChatMessage>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> closeConversation();
  Future<void> startConversation(String contactId);
  Future<void> sendMessage(String id, String text);
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> cancelPairing(String pairingId);
  Future<void> archivePairing(String pairingId);
  Future<void> updateAppVisibility(bool foreground);
}

ClientRuntime createClientRuntime() => createPlatformRuntime();
