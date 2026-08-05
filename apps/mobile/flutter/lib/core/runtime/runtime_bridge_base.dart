import '../../client_runtime.dart';
import '../application_state/application_snapshot.dart';
import 'runtime_arguments.dart';
import 'runtime_contract.dart';
import 'runtime_payload.dart';

abstract interface class RuntimeCallBridge {
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]);
}

mixin RuntimeBridgeMethods implements ClientRuntime, RuntimeProjectionProvider {
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
  Future<StartupReadinessSnapshot> startupReadiness() async {
    final value = await callRuntime(EngineContract.getStartupReadiness);
    if (value is! Map) {
      throw StateError('Engine returned an invalid startup readiness snapshot');
    }
    return StartupReadinessSnapshot.fromJson(
      value.map((key, item) => MapEntry(key.toString(), item)),
    );
  }

  @override
  Future<ApplicationSnapshot?> applicationSnapshot() async {
    final value = await callRuntime(EngineContract.getApplicationSnapshot);
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final projection = map['projection'];
    final stamp = projection is Map
        ? Map<String, dynamic>.from(projection)
        : const <String, dynamic>{};
    final identity = map['identity'] is Map
        ? RuntimeIdentity.fromMap(
            Map<String, dynamic>.from(map['identity'] as Map),
          )
        : const RuntimeIdentity();
    final profile = map['profile'] is Map
        ? RuntimeProfile.fromMap(
            Map<String, dynamic>.from(map['profile'] as Map),
          )
        : const RuntimeProfile();
    final contacts = (map['contacts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => ContactRecord.fromMap(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    final conversations = (map['conversations'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              ConversationSummary.fromMap(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
    final pairingInbox = (map['pairingInbox'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => PairingItem.fromMap(
            Map<String, dynamic>.from(item),
            origin: PairingOrigin.inbox,
          ),
        )
        .toList(growable: false);
    final pairingOutbox = (map['pairingOutbox'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => PairingItem.fromMap(
            Map<String, dynamic>.from(item),
            origin: PairingOrigin.outbox,
          ),
        )
        .toList(growable: false);
    final pairing = map['pairingSummary'] is Map
        ? Map<String, dynamic>.from(map['pairingSummary'] as Map)
        : const <String, dynamic>{};
    return ApplicationSnapshot(
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 2,
      generation: (map['generation'] as num?)?.toInt() ?? 0,
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ?? 0,
      identity: identity,
      profile: profile,
      contacts: contacts,
      conversations: conversations,
      pairingInbox: pairingInbox,
      pairingOutbox: pairingOutbox,
      pendingInbox: (pairing['pendingInbox'] as num?)?.toInt() ?? 0,
      pendingOutbox: (pairing['pendingOutbox'] as num?)?.toInt() ?? 0,
      peerEndpointAvailable: map['peerEndpointAvailable'] as bool? ?? false,
      projectionStoreId: stamp['storeId']?.toString() ?? '',
      projectionSessionId: stamp['engineSessionId']?.toString() ?? '',
      projectionRevision: (stamp['revision'] as num?)?.toInt() ?? 0,
    );
  }

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
          )
          .map(
            (payload) => PairingItem.fromMap(
              payload.toMap(),
              origin: PairingOrigin.inbox,
            ),
          )
          .toList();

  @override
  Future<List<PairingItem>> pairingOutbox() async =>
      RuntimePayload.itemsFromDynamicOrNull(
            await callRuntime(EngineContract.pairingOutbox),
          )
          .map(
            (payload) => PairingItem.fromMap(
              payload.toMap(),
              origin: PairingOrigin.outbox,
            ),
          )
          .toList();

  @override
  Future<List<PairingItem>> listPairings() async {
    final raw = await callRuntime(EngineContract.listPairings);
    if (raw is! Map) return const <PairingItem>[];
    final map = Map<String, dynamic>.from(raw);
    final inbox = RuntimePayload.itemsFromDynamicOrNull(map['inbox'])
        .map(
          (payload) => PairingItem.fromMap(
            payload.toMap(),
            origin: PairingOrigin.inbox,
          ),
        );
    final outbox = RuntimePayload.itemsFromDynamicOrNull(map['outbox'])
        .map(
          (payload) => PairingItem.fromMap(
            payload.toMap(),
            origin: PairingOrigin.outbox,
          ),
        );
    return <PairingItem>[...inbox, ...outbox];
  }

  @override
  Future<PeerEndpoint?> peerEndpoint() async =>
      RuntimePayload.fromDynamicOrNull(
        await callRuntime(EngineContract.getPeerEndpoint),
      )?.peerEndpoint();

  @override
  Future<bool> peerEndpointAvailable() async {
    try {
      return (await peerEndpoint()) != null;
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('peer endpoint') ||
          message.contains('endpoint not found') ||
          message.contains('not found')) {
        return false;
      }
      rethrow;
    }
  }

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
  Future<void> retryPeerConnection(String installationId) => callRuntime(
    EngineContract.retryPeerConnection,
    RuntimeArguments.installationId(installationId),
  );

  @override
  Future<void> rotatePeerEndpoint() =>
      callRuntime(EngineContract.rotatePeerEndpoint);

  @override
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) async {
    final raw = await callRuntime(
      EngineContract.getContactEndpointCapability,
      RuntimeArguments.installationId(installationId),
    );
    if (raw is! Map) throw const FormatException('Invalid capability response');
    return ContactEndpointCapabilityStatus.fromMap(
      Map<String, dynamic>.from(raw),
    );
  }

  @override
  Future<void> rotateContactEndpointCapability(String installationId) =>
      callRuntime(
        EngineContract.rotateContactEndpointCapability,
        RuntimeArguments.installationId(installationId),
      );

  @override
  Future<void> revokeContactEndpointCapability(String installationId) =>
      callRuntime(
        EngineContract.revokeContactEndpointCapability,
        RuntimeArguments.installationId(installationId),
      );

  @override
  Future<void> verifyContact(String installationId) => callRuntime(
    EngineContract.verifyContact,
    RuntimeArguments.installationId(installationId),
  );

  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) async => RuntimePayload.fromDynamic(
    await callRuntime(
      EngineContract.updateContactSettings,
      RuntimeArguments.contactSettings(
        installationId,
        localAlias: localAlias,
        muted: muted,
        blocked: blocked,
        transportPolicy: transportPolicy?.wireValue,
      ),
    ),
  ).contact();

  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) => callRuntime(
    EngineContract.removeRelationship,
    RuntimeArguments.relationshipRemoval(
      installationId,
      preserveHistory: preserveHistory,
    ),
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
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => callRuntime(
    EngineContract.sendMessage,
    RuntimeArguments.message(id, text, replyToMessageId: replyToMessageId),
  );

  @override
  Future<void> retryMessage(String messageId) => callRuntime(
    EngineContract.retryMessage,
    RuntimeArguments.messageId(messageId),
  );

  @override
  Future<void> retryDeadLetter(String kind, String id) => callRuntime(
    EngineContract.retryDeadLetter,
    RuntimeArguments.deadLetter(kind, id),
  );

  Future<List<Map<String, dynamic>>> listDeadLetters() async {
    final raw = await callRuntime(EngineContract.listDeadLetters);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  @override
  Future<void> deleteMessageLocal(String messageId) => callRuntime(
    EngineContract.deleteMessageLocal,
    RuntimeArguments.messageId(messageId),
  );

  @override
  Future<void> setTyping(String conversationId, bool typing) => callRuntime(
    EngineContract.setTyping,
    RuntimeArguments.typing(conversationId, typing),
  );

  Future<void> setConversationFocus(String conversationId, bool focused) =>
      callRuntime(
        EngineContract.setConversationFocus,
        RuntimeArguments.conversationFocus(conversationId, focused),
      );

  @override
  Future<void> setPresence(bool online) => callRuntime(
    EngineContract.setPresence,
    RuntimeArguments.presence(online),
  );

  @override
  Future<void> sendReadReceipts(String conversationId) => callRuntime(
    EngineContract.sendReadReceipts,
    RuntimeArguments.id(conversationId),
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
