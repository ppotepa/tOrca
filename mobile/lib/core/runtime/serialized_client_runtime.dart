import 'dart:async';

import '../../client_runtime.dart';

/// Serializes calls to a process-backed runtime.
///
/// The desktop JSON-lines bridge lazily starts its Rust sidecar. Without a
/// cross-command gate, startup events and UI refreshes can race and launch
/// multiple sidecars against the same SQLite database and Tor data directory.
/// Keeping one ordered command stream also makes restart behavior deterministic.
final class SerializedClientRuntime implements ClientRuntime {
  SerializedClientRuntime(this._delegate);

  final ClientRuntime _delegate;
  Future<void> _tail = Future<void>.value();

  Future<T> _run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail
        .catchError((Object _) {})
        .then<void>((_) async {
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
    () => _delegate.sendMessage(
      id,
      text,
      replyToMessageId: replyToMessageId,
    ),
  );

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
