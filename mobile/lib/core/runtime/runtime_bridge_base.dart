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

mixin RuntimeBridgeMethods implements ClientRuntime {
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]);

  @override
  Future<bool> connect() async =>
      await callRuntime(EngineContract.connect) as bool;

  @override
  Future<RuntimeIdentity?> identity() async => RuntimePayload.fromDynamicOrNull(
    await callRuntime(EngineContract.getIdentity),
  )?.identity();

  @override
  Future<RuntimeProfile?> profile() async => RuntimePayload.fromDynamicOrNull(
    await callRuntime(EngineContract.getProfile),
  )?.profile();

  @override
  Future<InviteCode?> refreshPairingCode() async =>
      RuntimePayload.fromDynamicOrNull(
        await callRuntime(EngineContract.refreshPairingCode),
      )?.inviteCode();

  @override
  Future<RuntimeProfile> setNickname(String nickname) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          EngineContract.setNickname,
          RuntimeArguments.nickname(nickname),
        ),
      ).profile();

  @override
  Future<PairingItem> submitPairingCode(String code) async =>
      RuntimePayload.fromDynamic(
        await callRuntime(
          EngineContract.submitPairingCode,
          RuntimeArguments.code(code),
        ),
      ).pairingItem();

  @override
  Future<List<PairingItem>> pairingInbox() async =>
      RuntimePayload.itemsFromDynamicOrNull(
        await callRuntime(EngineContract.pairingInbox),
      ).map((payload) => payload.pairingItem()).toList();

  @override
  Future<List<PairingItem>> pairingOutbox() async =>
      RuntimePayload.itemsFromDynamicOrNull(
        await callRuntime(EngineContract.pairingOutbox),
      ).map((payload) => payload.pairingItem()).toList();

  @override
  Future<void> acceptPairing(String pairingId) => callRuntime(
    EngineContract.acceptPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> rejectPairing(String pairingId) => callRuntime(
    EngineContract.rejectPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> cancelPairing(String pairingId) => callRuntime(
    EngineContract.cancelPairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> archivePairing(String pairingId) => callRuntime(
    EngineContract.archivePairing,
    RuntimeArguments.pairingId(pairingId),
  );

  @override
  Future<void> verifyContact(String installationId) => callRuntime(
    EngineContract.verifyContact,
    RuntimeArguments.installationId(installationId),
  );

  @override
  Future<List<ContactRecord>> contacts() async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(EngineContract.listContacts),
      ).map((payload) => payload.contact()).toList();

  @override
  Future<List<ConversationSummary>> conversations() async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(EngineContract.listConversations),
      ).map((payload) => payload.conversation()).toList();

  @override
  Future<List<ChatMessage>> messages(String id) async =>
      RuntimePayload.listFromDynamicOrNull(
        await callRuntime(EngineContract.listMessages, RuntimeArguments.id(id)),
      ).map((payload) => payload.message()).toList();

  @override
  Future<void> openConversation(String id) =>
      callRuntime(EngineContract.openConversation, RuntimeArguments.id(id));

  @override
  Future<void> closeConversation() =>
      callRuntime(EngineContract.closeConversation);

  @override
  Future<void> startConversation(String contactId) => callRuntime(
    EngineContract.startConversation,
    RuntimeArguments.contactId(contactId),
  );

  @override
  Future<void> sendMessage(String id, String text) => callRuntime(
    EngineContract.sendMessage,
    RuntimeArguments.message(id, text),
  );

  @override
  Future<void> updateAppVisibility(bool foreground) => callRuntime(
    EngineContract.platformFact,
    RuntimeArguments.fact({
      EngineContract.type: EngineContract.factAppVisibilityChanged,
      EngineContract.foreground: foreground,
    }),
  );
}
