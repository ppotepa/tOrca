import 'dart:async';
import 'dart:io';

import 'windows_runtime.dart';
export 'core/models/domain.dart';
import 'core/models/domain.dart';

/// Platform-neutral contract consumed by the Flutter UI.
abstract interface class ClientRuntime {
  Stream<RuntimeEvent> get events;
  Future<bool> connect();

  /// Returns process-owned runtime state when the platform keeps the engine
  /// alive independently from Flutter. Desktop and test runtimes may return
  /// null and use the normal cold-start path.
  Future<Map<String, dynamic>?> runtimeSnapshot() async => null;

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

/// Keeps process-backed desktop calls on one ordered command stream.
/// This prevents concurrent lazy starts from launching multiple Rust sidecars
/// against the same SQLite database and Tor data directory.
final class _SerializedClientRuntime implements ClientRuntime {
  _SerializedClientRuntime(this._delegate);

  final ClientRuntime _delegate;
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
  Stream<RuntimeEvent> get events => _delegate.events;
  @override
  Future<bool> connect() => _run(_delegate.connect);
  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() =>
      _run(_delegate.runtimeSnapshot);
  @override
  Future<RuntimeIdentity?> identity() => _run(_delegate.identity);
  @override
  Future<RuntimeProfile?> profile() => _run(_delegate.profile);
  @override
  Future<InviteCode?> refreshPairingCode() => _run(_delegate.refreshPairingCode);
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
  Future<PeerEndpoint?> peerEndpoint() => _run(_delegate.peerEndpoint);
  @override
  Future<bool> peerEndpointAvailable() => _run(_delegate.peerEndpointAvailable);
  @override
  Future<void> retryPeerConnection(String installationId) =>
      _run(() => _delegate.retryPeerConnection(installationId));
  @override
  Future<void> rotatePeerEndpoint() => _run(_delegate.rotatePeerEndpoint);
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
  }) => _run(() => _delegate.updateContactSettings(
    installationId,
    localAlias: localAlias,
    muted: muted,
    blocked: blocked,
    transportPolicy: transportPolicy,
  ));
  @override
  Future<List<ContactRecord>> contacts() => _run(_delegate.contacts);
  @override
  Future<List<ConversationSummary>> conversations() => _run(_delegate.conversations);
  @override
  Future<List<ChatMessage>> messages(String id) => _run(() => _delegate.messages(id));
  @override
  Future<void> openConversation(String id) => _run(() => _delegate.openConversation(id));
  @override
  Future<void> closeConversation() => _run(_delegate.closeConversation);
  @override
  Future<void> startConversation(String contactId) =>
      _run(() => _delegate.startConversation(contactId));
  @override
  Future<void> sendMessage(String id, String text, {String? replyToMessageId}) =>
      _run(() => _delegate.sendMessage(id, text, replyToMessageId: replyToMessageId));
  @override
  Future<void> retryMessage(String messageId) =>
      _run(() => _delegate.retryMessage(messageId));
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _run(() => _delegate.deleteMessageLocal(messageId));
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _run(() => _delegate.setTyping(conversationId, typing));
  @override
  Future<void> setPresence(bool online) => _run(() => _delegate.setPresence(online));
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
  final runtime = createPlatformRuntime();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return _SerializedClientRuntime(runtime);
  }
  return runtime;
}
