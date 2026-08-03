import 'dart:async';
import 'dart:io';

import 'core/application_state/application_snapshot.dart';
import 'windows_runtime.dart';
export 'core/models/domain.dart';
import 'core/models/domain.dart';

/// Optional capability for platforms whose native process outlives Flutter UI.
abstract interface class RuntimeAttachmentProvider {
  Future<Map<String, dynamic>?> runtimeSnapshot();
}

abstract interface class RuntimeProjectionProvider {
  Future<ApplicationSnapshot?> applicationSnapshot();
}

/// Optional lifecycle hook for runtimes that own an external process. Mobile
/// foreground-service bridges intentionally do not implement it.
abstract interface class RuntimeDisposable {
  Future<void> disposeRuntime();
}

/// Platform-neutral contract consumed by the Flutter UI.
abstract class ClientRuntime {
  Stream<RuntimeEvent> get events;

  Future<bool> connect();
  Future<RuntimeIdentity?> identity();
  Future<RuntimeProfile?> profile();
  Future<StartupReadinessSnapshot> startupReadiness();
  Future<InviteCode?> refreshPairingCode();
  Future<RuntimeProfile> setNickname(String nickname);
  Future<PairingItem> submitPairingCode(String code);
  Future<List<PairingItem>> pairingInbox();
  Future<List<PairingItem>> pairingOutbox();
  Future<List<PairingItem>> listPairings();
  Future<PeerEndpoint?> peerEndpoint();
  Future<bool> peerEndpointAvailable();
  Future<void> retryPeerConnection(String installationId);
  Future<void> rotatePeerEndpoint();
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) async => throw UnsupportedError('contact capability status unavailable');
  Future<void> rotateContactEndpointCapability(String installationId) async {}
  Future<void> revokeContactEndpointCapability(String installationId) async {}
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
  }) async {}
  Future<List<ContactRecord>> contacts();
  Future<List<ConversationSummary>> conversations();
  Future<List<ChatMessage>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> closeConversation();
  Future<void> startConversation(String contactId);
  Future<void> sendMessage(String id, String text, {String? replyToMessageId});
  Future<void> retryMessage(String messageId) async {}
  Future<void> retryDeadLetter(String kind, String id) async {}
  Future<void> deleteMessageLocal(String messageId) async {}
  Future<void> setTyping(String conversationId, bool typing) async {}
  Future<void> setPresence(bool online) async {}
  Future<void> sendReadReceipts(String conversationId) async {
    throw UnsupportedError('read receipts disabled by runtime');
  }
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> cancelPairing(String pairingId);
  Future<void> archivePairing(String pairingId);
  Future<void> updateAppVisibility(bool foreground);
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
    if (_delegate is RuntimeDisposable) {
      await (_delegate as RuntimeDisposable).disposeRuntime();
    }
  }

  @override
  Future<ApplicationSnapshot?> applicationSnapshot() async {
    final provider = _delegate;
    if (provider is! RuntimeProjectionProvider) return null;
    return (provider as RuntimeProjectionProvider).applicationSnapshot();
  }

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    if (_delegate is! RuntimeAttachmentProvider) return null;
    // This snapshot is bootstrap metadata only. RuntimeRepository owns the
    // canonical typed projection and is the sole ApplicationStateStore writer.
    return (_delegate as RuntimeAttachmentProvider).runtimeSnapshot();
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
  Future<List<PairingItem>> pairingInbox() => _delegate.pairingInbox();
  @override
  Future<List<PairingItem>> pairingOutbox() => _delegate.pairingOutbox();
  @override
  Future<List<PairingItem>> listPairings() => _delegate.listPairings();
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
  Future<List<Map<String, dynamic>>> listDeadLetters() =>
      (_delegate as dynamic).listDeadLetters();
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _delegate.deleteMessageLocal(messageId);
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _delegate.setTyping(conversationId, typing);
  Future<void> setConversationFocus(String conversationId, bool focused) =>
      (_delegate as dynamic).setConversationFocus(conversationId, focused);
  @override
  Future<void> setPresence(bool online) => _delegate.setPresence(online);
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      _delegate.sendReadReceipts(conversationId);
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
  Future<void> updateAppVisibility(bool foreground) =>
      _delegate.updateAppVisibility(foreground);
}

/// Keeps process-backed desktop calls on one ordered command stream.
final class _SerializedClientRuntime
    implements ClientRuntime, RuntimeProjectionProvider, RuntimeDisposable {
  _SerializedClientRuntime(this._delegate);

  final ClientRuntime _delegate;

  @override
  Future<void> disposeRuntime() async {
    if (_delegate is RuntimeDisposable) {
      await (_delegate as RuntimeDisposable).disposeRuntime();
    }
  }

  Future<void> _tail = Future<void>.value();

  Future<T> _run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.catchError((Object _) {}).then<void>((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Future<ApplicationSnapshot?> applicationSnapshot() {
    final provider = _delegate;
    if (provider is! RuntimeProjectionProvider) return Future.value(null);
    return _run((provider as RuntimeProjectionProvider).applicationSnapshot);
  }

  @override
  Stream<RuntimeEvent> get events => _delegate.events;
  @override
  Future<bool> connect() => _run(_delegate.connect);
  @override
  Future<RuntimeIdentity?> identity() => _run(_delegate.identity);
  @override
  Future<RuntimeProfile?> profile() => _run(_delegate.profile);
  @override
  Future<StartupReadinessSnapshot> startupReadiness() =>
      _run(_delegate.startupReadiness);
  @override
  Future<InviteCode?> refreshPairingCode() =>
      _run(_delegate.refreshPairingCode);
  @override
  Future<RuntimeProfile> setNickname(String nickname) =>
      _run(() => _delegate.setNickname(nickname));
  @override
  Future<PairingItem> submitPairingCode(String code) =>
      _run(() => _delegate.submitPairingCode(code));
  @override
  Future<List<PairingItem>> pairingInbox() => _run(_delegate.pairingInbox);
  @override
  Future<List<PairingItem>> pairingOutbox() => _run(_delegate.pairingOutbox);
  @override
  Future<List<PairingItem>> listPairings() => _run(_delegate.listPairings);
  @override
  Future<PeerEndpoint?> peerEndpoint() => _run(_delegate.peerEndpoint);
  @override
  Future<bool> peerEndpointAvailable() => _run(_delegate.peerEndpointAvailable);
  @override
  Future<void> retryPeerConnection(String installationId) =>
      _run(() => _delegate.retryPeerConnection(installationId));
  @override
  Future<void> rotatePeerEndpoint() => _run(_delegate.rotatePeerEndpoint);
  @override
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) => _run(() => _delegate.contactEndpointCapability(installationId));
  @override
  Future<void> rotateContactEndpointCapability(String installationId) =>
      _run(() => _delegate.rotateContactEndpointCapability(installationId));
  @override
  Future<void> revokeContactEndpointCapability(String installationId) =>
      _run(() => _delegate.revokeContactEndpointCapability(installationId));
  @override
  Future<void> verifyContact(String installationId) =>
      _run(() => _delegate.verifyContact(installationId));
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) => _run(
    () => _delegate.updateContactSettings(
      installationId,
      localAlias: localAlias,
      muted: muted,
      blocked: blocked,
      transportPolicy: transportPolicy,
    ),
  );
  @override
  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) => _run(
    () => _delegate.removeRelationship(
      installationId,
      preserveHistory: preserveHistory,
    ),
  );
  @override
  Future<List<ContactRecord>> contacts() => _run(_delegate.contacts);
  @override
  Future<List<ConversationSummary>> conversations() =>
      _run(_delegate.conversations);
  @override
  Future<List<ChatMessage>> messages(String id) =>
      _run(() => _delegate.messages(id));
  @override
  Future<void> openConversation(String id) =>
      _run(() => _delegate.openConversation(id));
  @override
  Future<void> closeConversation() => _run(_delegate.closeConversation);
  @override
  Future<void> startConversation(String contactId) =>
      _run(() => _delegate.startConversation(contactId));
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => _run(
    () => _delegate.sendMessage(id, text, replyToMessageId: replyToMessageId),
  );
  @override
  Future<void> retryMessage(String messageId) =>
      _run(() => _delegate.retryMessage(messageId));
  @override
  Future<void> retryDeadLetter(String kind, String id) =>
      _run(() => _delegate.retryDeadLetter(kind, id));
  Future<List<Map<String, dynamic>>> listDeadLetters() =>
      _run(() => (_delegate as dynamic).listDeadLetters());
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _run(() => _delegate.deleteMessageLocal(messageId));
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _run(() => _delegate.setTyping(conversationId, typing));
  Future<void> setConversationFocus(String conversationId, bool focused) =>
      _run(
        () => (_delegate as dynamic).setConversationFocus(
          conversationId,
          focused,
        ),
      );
  @override
  Future<void> setPresence(bool online) =>
      _run(() => _delegate.setPresence(online));
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      _run(() => _delegate.sendReadReceipts(conversationId));
  @override
  Future<void> acceptPairing(String pairingId) =>
      _run(() => _delegate.acceptPairing(pairingId));
  @override
  Future<void> rejectPairing(String pairingId) =>
      _run(() => _delegate.rejectPairing(pairingId));
  @override
  Future<void> cancelPairing(String pairingId) =>
      _run(() => _delegate.cancelPairing(pairingId));
  @override
  Future<void> archivePairing(String pairingId) =>
      _run(() => _delegate.archivePairing(pairingId));
  @override
  Future<void> updateAppVisibility(bool foreground) =>
      _run(() => _delegate.updateAppVisibility(foreground));
}

ClientRuntime createClientRuntime() {
  final platform = createPlatformRuntime();
  final ordered = Platform.isWindows || Platform.isLinux || Platform.isMacOS
      ? _SerializedClientRuntime(platform)
      : platform;
  return _SessionAwareClientRuntime(ordered);
}
