import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

/// Process and lifecycle boundary shared by all Torca hosts.
abstract interface class RuntimeLifecycleCapability {
  Stream<RuntimeEvent> get events;

  Future<bool> connect();
  Future<void> updateAppVisibility(bool foreground);
}

/// Adapter-only compatibility surface for direct pairing reads. Application
/// code must consume pairing from the revisioned application snapshot instead.
abstract interface class RuntimePairingQueryCapability {
  Future<List<PairingItem>> pairingInbox();
  Future<List<PairingItem>> pairingOutbox();
  Future<List<PairingItem>> listPairings();
}

/// The single authoritative domain projection consumed by Flutter. Native
/// bridges may still expose direct pairing reads while their generated
/// adapters are migrated, but application code receives only this capability.
abstract interface class RuntimeProjectionCapability
    implements RuntimePairingQueryCapability {
  Future<ApplicationSnapshot?> applicationSnapshot();
}

abstract interface class RuntimeProfileCapability {
  Future<RuntimeIdentity?> identity();
  Future<RuntimeProfile?> profile();
  Future<StartupReadinessSnapshot> startupReadiness();
  Future<RuntimeProfile> setNickname(String nickname);
}

abstract interface class RuntimePairingCapability {
  Future<InviteCode?> refreshPairingCode();
  Future<PairingItem> submitPairingCode(String code);
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> cancelPairing(String pairingId);
  Future<void> archivePairing(String pairingId);
}

abstract interface class RuntimeContactCapability {
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  );
  Future<void> rotateContactEndpointCapability(String installationId);
  Future<void> revokeContactEndpointCapability(String installationId);
  Future<void> verifyContact(String installationId);
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  });
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  });
  Future<List<ContactRecord>> contacts();
}

abstract interface class RuntimeConversationCapability {
  Future<List<ConversationSummary>> conversations();
  Future<List<ChatMessage>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> closeConversation();
  Future<void> startConversation(String contactId);
  Future<void> setConversationFocus(String conversationId, bool focused);
}

abstract interface class RuntimeMessagingCapability {
  Future<void> sendMessage(String id, String text, {String? replyToMessageId});
  Future<void> retryMessage(String messageId);
  Future<void> retryDeadLetter(String kind, String id);
  Future<List<Map<String, dynamic>>> listDeadLetters();
  Future<void> deleteMessageLocal(String messageId);
  Future<void> setTyping(String conversationId, bool typing);
  Future<void> setPresence(bool online);
  Future<void> sendReadReceipts(String conversationId);
}

abstract interface class RuntimePeerCapability {
  Future<PeerEndpoint?> peerEndpoint();
  Future<bool> peerEndpointAvailable();
  Future<void> retryPeerConnection(String installationId);
  Future<void> rotatePeerEndpoint();
}
