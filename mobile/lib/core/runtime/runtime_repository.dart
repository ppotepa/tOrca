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
  Future<PairingPreparation> prepareAcceptInvite(String id) {
    return _runtime.prepareAcceptPairing(id);
  }

  Future<void> acceptPairing(String id) => _runtime.acceptPairing(id);

  Future<RuntimeSendEffect> commitAcceptInvite(
    String id,
    String offerInviteId,
    String offerPayload,
  ) {
    return _runtime.commitAcceptPairing(id, offerInviteId, offerPayload);
  }

  Future<PairingPreparation> prepareRejectInvite(String id) {
    return _runtime.prepareRejectPairing(id);
  }

  Future<void> rejectPairing(String id) => _runtime.rejectPairing(id);

  Future<RuntimeSendEffect> commitRejectInvite(String id) {
    return _runtime.commitRejectPairing(id);
  }

  Future<void> archiveInvite(String id) {
    final runtime = _runtime;
    if (runtime is! PairingArchiveRuntime) {
      return Future<void>.error(
        UnsupportedError(
          'Archiwizacja zaproszeń nie jest dostępna w tym runtime.',
        ),
      );
    }
    return (runtime as PairingArchiveRuntime).archivePairing(id);
  }

  Future<PairingCancelEffect> prepareCancelPairing(String id) {
    return _runtime.prepareCancelPairing(id);
  }

  Future<void> cancelPairing(String id) => _runtime.cancelPairing(id);

  Future<void> confirmPairingCancelled(String id) {
    return _runtime.confirmPairingCancelled(id);
  }

  Future<void> verifyContact(String id) => _runtime.verifyContact(id);
  Future<List<ContactRecord>> contacts() async => await _runtime.contacts();
  Future<List<ConversationSummary>> conversations() async =>
      await _runtime.conversations();
  Future<List<ChatMessage>> messages(String id) async =>
      await _runtime.messages(id);
  Future<List<PairingItem>> inbox() async => await _runtime.pairingInbox();
  Future<List<PairingItem>> outbox() async => await _runtime.pairingOutbox();
  Future<void> openConversation(String id) => _runtime.openConversation(id);
  Future<void> closeConversation() => _runtime.closeConversation();
  Future<void> startConversation(String id) => _runtime.startConversation(id);
  Future<void> sendMessage(String id, String text) =>
      _runtime.sendMessage(id, text);
}
