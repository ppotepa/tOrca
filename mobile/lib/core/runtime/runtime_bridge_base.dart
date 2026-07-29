import '../../client_runtime.dart';
import 'runtime_arguments.dart';
import 'runtime_contract.dart';
import 'runtime_payload.dart';

abstract interface class RuntimeCallBridge {
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]);
}

mixin RuntimeBridgeMethods
    implements
        ClientRuntime,
        PairingArchiveRuntime {
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]);

  @override
  Future<bool> connect() async =>
      await callRuntime(RuntimeContract.connect) as bool;

  @override
  Future<RuntimeIdentity?> identity() async => RuntimePayload.fromDynamicOrNull(
    await callRuntime(RuntimeContract.identity),
  )?.identity();

  @override
  Future<RuntimeProfile?> profile() async => RuntimePayload.fromDynamicOrNull(
    await callRuntime(RuntimeContract.profile),
  )?.profile();

  @override
  Future<InviteCode?> refreshPairingCode() async =>
      RuntimePayload.fromDynamicOrNull(
        await callRuntime(RuntimeContract.refreshPairingCode),
      )?.inviteCode();

  @override
  Future<RuntimeProfile> setNickname(String nickname) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.setNickname,
          RuntimeArguments.nickname(nickname),
        ),
      ).profile();

  @override
  Future<PairingItem> submitPairingCode(String code) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.submitPairingCode,
          RuntimeArguments.code(code),
        ),
      ).pairingItem();

  @override
  Future<List<PairingItem>> pairingInbox() async =>
      RuntimePayload.itemsFromDynamicOrNull(
        await callRuntime(RuntimeContract.pairingInbox),
      ).map((payload) => payload.pairingItem()).toList();

  @override
  Future<List<PairingItem>> pairingOutbox() async =>
      RuntimePayload.itemsFromDynamicOrNull(
        await callRuntime(RuntimeContract.pairingOutbox),
      ).map((payload) => payload.pairingItem()).toList();

  @override
  Future<void> acceptPairing(String pairingId) => callRuntime(
    RuntimeContract.acceptPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> rejectPairing(String pairingId) => callRuntime(
    RuntimeContract.rejectPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> cancelPairing(String pairingId) => callRuntime(
    RuntimeContract.cancelPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<PairingPreparation> prepareAcceptPairing(String pairingId) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.prepareAcceptPairing,
          RuntimeArguments.pairingId(pairingId),
        ),
      ).pairingPreparation();

  @override
  Future<RuntimeSendEffect> commitAcceptPairing(
    String pairingId,
    String offerInviteId,
    String offerPayload,
  ) async => RuntimePayload.fromDynamic(
    await callRuntime(
      RuntimeContract.commitAcceptPairing,
      RuntimeArguments.map({
        'pairingId': pairingId,
        'offerInviteId': offerInviteId,
        'offerPayload': offerPayload,
      }),
    ),
  ).runtimeSendEffect();

  @override
  Future<PairingPreparation> prepareRejectPairing(String pairingId) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.prepareRejectPairing,
          RuntimeArguments.pairingId(pairingId),
        ),
      ).pairingPreparation();

  @override
  Future<RuntimeSendEffect> commitRejectPairing(String pairingId) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.commitRejectPairing,
          RuntimeArguments.pairingId(pairingId),
        ),
      ).runtimeSendEffect();

  @override
  Future<void> archivePairing(String pairingId) => callRuntime(
    RuntimeContract.archivePairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<PairingCancelEffect> prepareCancelPairing(String pairingId) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          RuntimeContract.prepareCancelPairing,
          RuntimeArguments.pairingId(pairingId),
        ),
      ).pairingCancelEffect();

  @override
  Future<void> confirmPairingCancelled(String pairingId) => callRuntime(
    RuntimeContract.confirmPairingCancelled,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> verifyContact(String installationId) => callRuntime(
    RuntimeContract.verifyContact,
    RuntimeArguments.installationId(installationId),
  );

  @override
  Future<List<ContactRecord>> contacts() async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(RuntimeContract.contacts),
      ).map((payload) => payload.contact()).toList();

  @override
  Future<List<ConversationSummary>> conversations() async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(RuntimeContract.conversations),
      ).map((payload) => payload.conversation()).toList();

  @override
  Future<List<ChatMessage>> messages(String id) async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(RuntimeContract.messages, RuntimeArguments.id(id)),
      ).map((payload) => payload.message()).toList();

  @override
  Future<void> openConversation(String id) =>
      callRuntime(RuntimeContract.openConversation, RuntimeArguments.id(id));

  @override
  Future<void> closeConversation() =>
      callRuntime(RuntimeContract.closeConversation);

  @override
  Future<void> startConversation(String contactId) => callRuntime(
    RuntimeContract.startConversation,
    RuntimeArguments.contactId(contactId),
  );

  @override
  Future<void> sendMessage(String id, String text) => callRuntime(
    RuntimeContract.sendMessage,
    RuntimeArguments.message(id, text),
  );
}
