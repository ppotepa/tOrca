import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
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
    expect(runtime.listPairingsCalls, 1);
    expect(runtime.pairingInboxCalls, 0);
    expect(runtime.pairingOutboxCalls, 0);
  });

  test('forced profile read bypasses a stale application projection', () async {
    final runtime = _SnapshotRuntime();
    final repository = RuntimeRepository(runtime);
    repository.applicationState.hydrate(
      const ApplicationSnapshot(
        profile: RuntimeProfile(nickname: ''),
        generation: 1,
      ),
    );

    expect((await repository.profile()).nickname, isEmpty);
    expect((await repository.profile(force: true)).nickname, 'Alice');
  });

  test('nickname update does not advance authoritative generation', () async {
    final repository = RuntimeRepository(_SnapshotRuntime());
    repository.applicationState.hydrate(
      const ApplicationSnapshot(
        generation: 7,
        projectionStoreId: 'engine-store',
        projectionRevision: 12,
        profile: RuntimeProfile(nickname: 'Alice'),
      ),
    );

    await repository.setNickname('Alicja');

    expect(repository.applicationState.current?.generation, 7);
    expect(repository.applicationState.current?.projectionRevision, 12);
    expect(repository.applicationState.current?.profile.nickname, 'Alicja');
  });

  test(
    'refresh returns its transaction snapshot when cache is invalidated',
    () async {
      final runtime = _SnapshotRuntime();
      final repository = RuntimeRepository(runtime);

      final refresh = repository.refresh(includePairing: true);
      repository.invalidateLocalCache();
      final result = await refresh;

      expect(result.local.contacts.single.id, 'bob');
      expect(result.local.conversations.single.id, 'conversation');
    },
  );

  test('message reads are lazy and reuse the in-memory LRU', () async {
    final runtime = _SnapshotRuntime();
    final repository = RuntimeRepository(runtime);
    final phases = <ConversationMessagesPhase>[];
    final revisions = <int>[];
    final subscription = repository.messageLoadStates.listen(
      (state) => phases.add(state.phase),
    );
    final messageSubscription = repository.applicationState
        .watchMessages('conversation')
        .listen((snapshot) => revisions.add(snapshot.revision));
    addTearDown(subscription.cancel);
    addTearDown(messageSubscription.cancel);

    final first = await repository.messages('conversation');
    final second = await repository.messages('conversation');

    expect(first.single.text, 'message');
    expect(second.single.text, 'message');
    expect(runtime.messageCalls, 1);
    expect(revisions, [0, 1]);
    expect(phases, [
      ConversationMessagesPhase.loading,
      ConversationMessagesPhase.ready,
    ]);
  });

  test(
    'a transient live projection never truncates retained chat history',
    () async {
      final runtime = _SnapshotRuntime(
        messageBatches: [
          const [
            ChatMessage(
              id: 'old-1',
              text: 'first',
              outgoing: false,
              state: MessageState.delivered,
              createdAt: '2026-08-02T10:00:00Z',
            ),
            ChatMessage(
              id: 'old-2',
              text: 'second',
              outgoing: true,
              state: MessageState.sent,
              createdAt: '2026-08-02T10:01:00Z',
            ),
          ],
          const [
            ChatMessage(
              id: 'new-3',
              text: 'latest',
              outgoing: false,
              state: MessageState.delivered,
              createdAt: '2026-08-02T10:02:00Z',
            ),
          ],
        ],
      );
      final repository = RuntimeRepository(runtime);

      await repository.messages('conversation');
      repository.invalidateMessages('conversation');
      final refreshed = await repository.messages('conversation', force: true);

      expect(refreshed.map((message) => message.id), [
        'old-1',
        'old-2',
        'new-3',
      ]);
      expect(
        repository.applicationState
            .messages('conversation')
            .map((message) => message.id),
        ['old-1', 'old-2', 'new-3'],
      );
    },
  );

  test(
    'live projection updates message state without duplicating the message',
    () async {
      final runtime = _SnapshotRuntime(
        messageBatches: [
          const [
            ChatMessage(
              id: 'outgoing',
              text: 'hello',
              outgoing: true,
              state: MessageState.sending,
              createdAt: '2026-08-02T10:00:00Z',
            ),
          ],
          const [
            ChatMessage(
              id: 'outgoing',
              text: 'hello',
              outgoing: true,
              state: MessageState.delivered,
              createdAt: '2026-08-02T10:00:00Z',
            ),
          ],
        ],
      );
      final repository = RuntimeRepository(runtime);

      await repository.messages('conversation');
      repository.invalidateMessages('conversation');
      final refreshed = await repository.messages('conversation', force: true);

      expect(refreshed, hasLength(1));
      expect(refreshed.single.state, MessageState.delivered);
    },
  );

  test(
    'live projection publishes every persisted message without reopening',
    () async {
      final runtime = _SnapshotRuntime(
        messageBatches: [
          const [
            ChatMessage(
              id: 'one',
              text: 'one',
              outgoing: true,
              state: MessageState.sent,
              createdAt: '2026-08-02T10:00:00Z',
            ),
          ],
          const [
            ChatMessage(
              id: 'one',
              text: 'one',
              outgoing: true,
              state: MessageState.delivered,
              createdAt: '2026-08-02T10:00:00Z',
            ),
            ChatMessage(
              id: 'two',
              text: 'two',
              outgoing: false,
              state: MessageState.delivered,
              createdAt: '2026-08-02T10:00:01Z',
            ),
            ChatMessage(
              id: 'three',
              text: 'three',
              outgoing: true,
              state: MessageState.queued,
              createdAt: '2026-08-02T10:00:02Z',
            ),
          ],
        ],
      );
      final repository = RuntimeRepository(runtime);
      final snapshots = <ConversationMessagesSnapshot>[];
      final subscription = repository.applicationState
          .watchMessages('conversation')
          .listen(snapshots.add);
      addTearDown(subscription.cancel);

      await repository.messages('conversation');
      repository.invalidateMessages('conversation');
      await repository.messages('conversation', force: true);

      expect(snapshots.last.messages.map((message) => message.text), [
        'one',
        'two',
        'three',
      ]);
      expect(
        snapshots.last.messages
            .singleWhere((message) => message.id == 'one')
            .state,
        MessageState.delivered,
      );
    },
  );

  test('changed native identity clears retained shell snapshot', () async {
    ApplicationStateStore.shared.hydrate(
      const ApplicationSnapshot(
        generation: 10,
        identity: RuntimeIdentity(installationId: 'old'),
        profile: RuntimeProfile(installationId: 'old', nickname: 'Old profile'),
      ),
    );
    final runtime = _SnapshotRuntime(installationId: 'new');
    final repository = RuntimeRepository(runtime);

    await repository.connect();
    final snapshot = await repository.applicationSnapshot();

    expect(snapshot.identity.installationId, 'new');
    expect(snapshot.profile.nickname, 'Alice');
    expect(
      ApplicationStateStore.shared.current?.identity.installationId,
      'new',
    );
  });

  test('peer connection event is the canonical live contact status', () async {
    final runtime = _SnapshotRuntime();
    addTearDown(runtime.dispose);
    final repository = RuntimeRepository(runtime);
    final event = repository.events.first;

    runtime.emit(
      const PeerConnectionChangedEvent(
        contactId: 'bob',
        status: PeerConnectionStatus.connected,
      ),
    );
    await event;

    final contacts = await repository.contacts();
    expect(
      contacts.single.peerConnectionStatus,
      PeerConnectionStatus.connected,
    );
  });
}

class _SnapshotRuntime implements ClientRuntime {
  _SnapshotRuntime({
    this.installationId = 'local',
    List<List<ChatMessage>> messageBatches = const [],
  }) : _messageBatches = List<List<ChatMessage>>.of(messageBatches);

  final String installationId;
  int pairingInboxCalls = 0;
  int pairingOutboxCalls = 0;
  int listPairingsCalls = 0;
  int messageCalls = 0;
  final List<List<ChatMessage>> _messageBatches;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast();

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  void emit(RuntimeEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();

  @override
  Future<bool> connect() async => true;
  @override
  Future<StartupReadinessSnapshot> startupReadiness() async =>
      const StartupReadinessSnapshot(
        engineReady: true,
        localDataReady: true,
        torReady: true,
        peerListenerReady: true,
        onionServiceReady: true,
        generation: 1,
        detail: 'test runtime ready',
      );

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
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) async {}

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
  Future<List<PairingItem>> listPairings() async {
    listPairingsCalls += 1;
    return const [
      PairingItem(
        id: 'inbox',
        status: InviteState.pending,
        availableActions: [PairingAvailableAction.accept],
        origin: PairingOrigin.inbox,
      ),
      PairingItem(
        id: 'outbox',
        status: InviteState.pending,
        received: false,
        origin: PairingOrigin.outbox,
      ),
    ];
  }

  @override
  Future<List<ChatMessage>> messages(String id) async {
    messageCalls += 1;
    if (_messageBatches.isNotEmpty) return _messageBatches.removeAt(0);
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
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) async => const ContactEndpointCapabilityStatus(
    contactId: '',
    capabilityId: '',
    sequence: 0,
    status: CapabilityStatus.missing,
  );
  @override
  Future<void> rotateContactEndpointCapability(String installationId) async {}
  @override
  Future<void> revokeContactEndpointCapability(String installationId) async {}
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
  Future<void> retryDeadLetter(String kind, String id) async {}
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
