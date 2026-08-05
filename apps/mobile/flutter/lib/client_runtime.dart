import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

import 'platform/platform_services.dart';
import 'runtime_capabilities.dart';

export 'package:torchat_flutter_ui/core/models/domain.dart';

abstract interface class RuntimeAttachmentProvider {
  Future<Map<String, dynamic>?> runtimeSnapshot();
}

abstract interface class RuntimeProjectionProvider
    implements RuntimeProjectionCapability {}

abstract interface class RuntimeDisposable {
  Future<void> disposeRuntime();
}

/// Platform-neutral frontend/backend boundary. Pairing collections are absent
/// and belong to the revisioned application projection.
abstract class ClientRuntime
    implements
        RuntimeLifecycleCapability,
        RuntimeProfileCapability,
        RuntimePairingCapability,
        RuntimeContactCapability,
        RuntimeConversationCapability,
        RuntimeMessagingCapability,
        RuntimePeerCapability {
  @override
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) => throw UnsupportedError('contact capability status unavailable');
  @override
  Future<void> rotateContactEndpointCapability(String installationId) =>
      throw UnsupportedError('contact capability rotation unavailable');
  @override
  Future<void> revokeContactEndpointCapability(String installationId) =>
      throw UnsupportedError('contact capability revocation unavailable');
  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) => throw UnsupportedError('relationship removal unavailable');
  @override
  Future<void> retryMessage(String messageId) =>
      throw UnsupportedError('message retry unavailable');
  @override
  Future<void> retryDeadLetter(String kind, String id) =>
      throw UnsupportedError('dead-letter retry unavailable');
  @override
  Future<List<Map<String, dynamic>>> listDeadLetters() =>
      throw UnsupportedError('dead-letter inspection unavailable');
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      throw UnsupportedError('local message deletion unavailable');
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      throw UnsupportedError('typing updates unavailable');
  @override
  Future<void> setConversationFocus(String conversationId, bool focused) =>
      throw UnsupportedError('conversation focus unavailable');
  @override
  Future<void> setPresence(bool online) =>
      throw UnsupportedError('presence updates unavailable');
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      throw UnsupportedError('read receipts unavailable');
}

final class _SessionAwareClientRuntime
    implements
        ClientRuntime,
        RuntimeAttachmentProvider,
        RuntimeProjectionProvider,
        RuntimeDisposable {
  _SessionAwareClientRuntime(this._delegate);

  final ClientRuntime _delegate;

  @override
  Future<void> disposeRuntime() async {
    final delegate = _delegate;
    if (delegate is RuntimeDisposable) await delegate.disposeRuntime();
  }

  @override
  Future<ApplicationSnapshot?> applicationSnapshot() async {
    final delegate = _delegate;
    if (delegate is! RuntimeProjectionCapability) return null;
    return delegate.applicationSnapshot();
  }

  RuntimePairingQueryCapability get _pairingQueries {
    final delegate = _delegate;
    if (delegate is! RuntimePairingQueryCapability) {
      throw UnsupportedError('direct pairing queries unavailable');
    }
    return delegate;
  }

  @override
  Future<List<PairingItem>> pairingInbox() => _pairingQueries.pairingInbox();
  @override
  Future<List<PairingItem>> pairingOutbox() => _pairingQueries.pairingOutbox();
  @override
  Future<List<PairingItem>> listPairings() => _pairingQueries.listPairings();

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    final delegate = _delegate;
    if (delegate is! RuntimeAttachmentProvider) return null;
    return delegate.runtimeSnapshot();
  }

  @override
  Stream<RuntimeEvent> get events => _delegate.events;
  @override
  Future<bool> connect() => _delegate.connect();
  @override
  Future<RuntimeIdentity?> identity() => _delegate.identity();
  @override
  Future<RuntimeProfile?> profile() => _delegate.profile();
  @override
  Future<StartupReadinessSnapshot> startupReadiness() =>
      _delegate.startupReadiness();
  @override
  Future<InviteCode?> refreshPairingCode() => _delegate.refreshPairingCode();
  @override
  Future<RuntimeProfile> setNickname(String nickname) =>
      _delegate.setNickname(nickname);
  @override
  Future<PairingItem> submitPairingCode(String code) =>
      _delegate.submitPairingCode(code);
  @override
  Future<void> acceptPairing(String pairingId) =>
      _delegate.acceptPairing(pairingId);
  @override
  Future<void> rejectPairing(String pairingId) =>
      _delegate.rejectPairing(pairingId);
  @override
  Future<void> cancelPairing(String pairingId) =>
      _delegate.cancelPairing(pairingId);
  @override
  Future<void> archivePairing(String pairingId) =>
      _delegate.archivePairing(pairingId);
  @override
  Future<PeerEndpoint?> peerEndpoint() => _delegate.peerEndpoint();
  @override
  Future<bool> peerEndpointAvailable() => _delegate.peerEndpointAvailable();
  @override
  Future<void> retryPeerConnection(String installationId) =>
      _delegate.retryPeerConnection(installationId);
  @override
  Future<void> rotatePeerEndpoint() => _delegate.rotatePeerEndpoint();
  @override
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) => _delegate.contactEndpointCapability(installationId);
  @override
  Future<void> rotateContactEndpointCapability(String installationId) =>
      _delegate.rotateContactEndpointCapability(installationId);
  @override
  Future<void> revokeContactEndpointCapability(String installationId) =>
      _delegate.revokeContactEndpointCapability(installationId);
  @override
  Future<void> verifyContact(String installationId) =>
      _delegate.verifyContact(installationId);
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) => _delegate.updateContactSettings(
    installationId,
    localAlias: localAlias,
    muted: muted,
    blocked: blocked,
    transportPolicy: transportPolicy,
  );
  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) => _delegate.removeRelationship(
    installationId,
    preserveHistory: preserveHistory,
  );
  @override
  Future<List<ContactRecord>> contacts() => _delegate.contacts();
  @override
  Future<List<ConversationSummary>> conversations() =>
      _delegate.conversations();
  @override
  Future<List<ChatMessage>> messages(String id) => _delegate.messages(id);
  @override
  Future<void> openConversation(String id) => _delegate.openConversation(id);
  @override
  Future<void> closeConversation() => _delegate.closeConversation();
  @override
  Future<void> startConversation(String contactId) =>
      _delegate.startConversation(contactId);
  @override
  Future<void> setConversationFocus(String conversationId, bool focused) =>
      _delegate.setConversationFocus(conversationId, focused);
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => _delegate.sendMessage(id, text, replyToMessageId: replyToMessageId);
  @override
  Future<void> retryMessage(String messageId) =>
      _delegate.retryMessage(messageId);
  @override
  Future<void> retryDeadLetter(String kind, String id) =>
      _delegate.retryDeadLetter(kind, id);
  @override
  Future<List<Map<String, dynamic>>> listDeadLetters() =>
      _delegate.listDeadLetters();
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _delegate.deleteMessageLocal(messageId);
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _delegate.setTyping(conversationId, typing);
  @override
  Future<void> setPresence(bool online) => _delegate.setPresence(online);
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      _delegate.sendReadReceipts(conversationId);
  @override
  Future<void> updateAppVisibility(bool foreground) =>
      _delegate.updateAppVisibility(foreground);
}

ClientRuntime createClientRuntime() {
  final platform = PlatformServices.current.runtimeBridgeFactory();
  return _SessionAwareClientRuntime(platform);
}
