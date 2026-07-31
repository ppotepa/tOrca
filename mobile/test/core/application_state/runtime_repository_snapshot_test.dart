import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/application_state/application_snapshot.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';
import 'package:torchat_mobile/core/runtime/runtime_repository.dart';

void main() {
  setUp(ApplicationStateStore.shared.clear);

  test('shell snapshot does not wait for pairing resources', () async {
    final runtime = _SnapshotRuntime();
    final repository = RuntimeRepository(runtime);

    final snapshot = await repository.applicationSnapshot();

    expect(snapshot.profile.nickname, 'Alice');
    expect(snapshot.contacts.single.nickname, 'Bob');
    expect(snapshot.conversations.single.preview, 'hello');
    expect(runtime.pairingInboxCalls, 0);
    expect(runtime.pairingOutboxCalls, 0);
  });

  test('pairing counters are loaded only when requested', () async {
    final runtime = _SnapshotRuntime();
    final repository = RuntimeRepository(runtime);

    final snapshot = await repository.applicationSnapshot(
      includePairing: true,
      force: true,
    );

    expect(snapshot.pendingInbox, 1);
    expect(snapshot.pendingOutbox, 1);
    expect(runtime.pairingInboxCalls, 1);
    expect(runtime.pairingOutboxCalls, 1);
  });

  test('message reads are lazy and reuse the in-memory LRU', () async {
    final runtime = _SnapshotRuntime();
    final repository = RuntimeRepository(runtime);
    final phases = <ConversationMessagesPhase>[];
    final subscription = repository.messageLoadStates.listen(
      (state) => phases.add(state.phase),
    );
    addTearDown(subscription.cancel);

    final first = await repository.messages('conversation');
    final second = await repository.messages('conversation');

    expect(first.single.text, 'message');
    expect(second.single.text, 'message');
    expect(runtime.messageCalls, 1);
    expect(phases, [
      ConversationMessagesPhase.loading,
      ConversationMessagesPhase.ready,
    ]);
  });

  test('changed native identity clears retained shell snapshot', () async {
    ApplicationStateStore.shared.hydrate(
      const ApplicationSnapshot(
        generation: 10,
        identity: RuntimeIdentity(installationId: 'old'),
        profile: RuntimeProfile(
          installationId: 'old',
          nickname: 'Old profile',
        ),
      ),
    );
    final runtime = _SnapshotRuntime(installationId: 'new');
    final repository = RuntimeRepository(runtime);

    await repository.connect();
    final snapshot = await repository.applicationSnapshot();

    expect(snapshot.identity.installationId, 'new');
    expect(snapshot.profile.nickname, 'Alice');
    expect(ApplicationStateStore.shared.current?.identity.installationId, 'new');
  });
}

class _SnapshotRuntime implements ClientRuntime {
  _SnapshotRuntime({this.installationId = 'local'});

  final String installationId;
  int pairingInboxCalls = 0;
  int pairingOutboxCalls = 0;
  int messageCalls = 0;

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();

  @override
  Future<bool> connect() async => true;

  @override
  Future<RuntimeIdentity?> identity() async => RuntimeIdentity(
    installationId: installationId,
    fingerprint: 'local-fingerprint',
    publicKey: 'local-key',
  );

  @override
  Future<RuntimeProfile?> profile() async => RuntimeProfile(
    installationId: installationId,
    nickname: 'Alice',
    fingerprint: 'local-fingerprint',
    publicKey: 'local-key',
  );

  @override
  Future<List<ContactRecord>> contacts() async => const [
    ContactRecord(
      id: 'bob',
      nickname: 'Bob',
      fingerprint: 'bob-fingerprint',
      publicKey: 'bob-key',
      verified: true,
    ),
  ];

  @override
  Future<List<ConversationSummary>> conversations() async => const [
    ConversationSummary(
      id: 'conversation',
      contactId: 'bob',
      preview: 'hello',
      unread: 1,
    ),
  ];

  @override
  Future<bool> peerEndpointAvailable() async => true;

  @override
  Future<List<PairingItem>> pairingInbox() async {
    pairingInboxCalls += 1;
    return const [
      PairingItem(
        id: 'inbox',
        status: InviteState.pending,
        availableActions: [PairingAvailableAction.accept],
      ),
    ];
  }

  @override
  Future<List<PairingItem>> pairingOutbox() async {
    pairingOutboxCalls += 1;
    return const [PairingItem(id: 'outbox', status: InviteState.pending)];
  }

  @override
  Future<List<ChatMessage>> messages(String id) async {
    messageCalls += 1;
    return const [
      ChatMessage(
        id: 'message',
        text: 'message',
        outgoing: false,
        state: MessageState.delivered,
      ),
    ];
  }

  @override
  Future<RuntimeProfile> setNickname(String nickname) async => RuntimeProfile(
    installationId: installationId,
    nickname: nickname,
    fingerprint: 'local-fingerprint',
    publicKey: 'local-key',
  );

  @override
  Future<InviteCode?> refreshPairingCode() async => null;
  @override
  Future<PairingItem> submitPairingCode(String code) async =>
      const PairingItem(id: 'submitted', status: InviteState.pending);
  @override
  Future<PeerEndpoint?> peerEndpoint() async => null;
  @override
  Future<void> retryPeerConnection(String installationId) async {}
  @override
  Future<void> rotatePeerEndpoint() async {}
  @override
  Future<void> verifyContact(String installationId) async {}
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) async => contacts().then((items) => items.single);
  @override
  Future<void> openConversation(String id) async {}
  @override
  Future<void> closeConversation() async {}
  @override
  Future<void> startConversation(String contactId) async {}
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {}
  @override
  Future<void> retryMessage(String messageId) async {}
  @override
  Future<void> deleteMessageLocal(String messageId) async {}
  @override
  Future<void> setTyping(String conversationId, bool typing) async {}
  @override
  Future<void> setPresence(bool online) async {}
  @override
  Future<void> sendReadReceipts(String conversationId) async {}
  @override
  Future<void> acceptPairing(String pairingId) async {}
  @override
  Future<void> rejectPairing(String pairingId) async {}
  @override
  Future<void> cancelPairing(String pairingId) async {}
  @override
  Future<void> archivePairing(String pairingId) async {}
  @override
  Future<void> updateAppVisibility(bool foreground) async {}
}
