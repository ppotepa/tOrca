import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/app/app_controller.dart';
import 'package:torchat_mobile/core/runtime/runtime_contract.dart';
import 'package:torchat_mobile/core/runtime/runtime_repository.dart';
import 'package:torchat_mobile/features/chats/chats_view.dart';
import 'package:torchat_mobile/features/contacts/contacts_view.dart';
import 'package:torchat_mobile/features/inbox/inbox_view.dart';
import 'package:torchat_mobile/features/invites/invite_scanner.dart';
import 'package:torchat_mobile/features/onboarding/onboarding_views.dart';
import 'package:torchat_mobile/features/shell/main_shell.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/runtime/runtime_payload.dart';
import 'package:torchat_mobile/shared/widgets/action_status_strip.dart';
import 'package:torchat_mobile/shared/widgets/counter_badge.dart';

ContactRecord _contact() => const ContactRecord(
  id: 'alice-installation',
  nickname: 'Alice',
  fingerprint: 'AA:BB',
  publicKey: 'public-key',
  verified: false,
);

void main() {
  RuntimeFixture fixture() => RuntimeFixture.fromMap(
    Map<String, dynamic>.from(
      jsonDecode(
            File('../common/internal-runtime-fixtures.json').readAsStringSync(),
          )
          as Map,
    ),
  );

  test('runtime contract exposes canonical method and event names', () {
    expect(
      const [
        EngineContract.bootstrap,
        EngineContract.connect,
        EngineContract.getIdentity,
        EngineContract.getProfile,
        EngineContract.pairingInbox,
        EngineContract.pairingOutbox,
        EngineContract.listContacts,
        EngineContract.listConversations,
        EngineContract.listMessages,
        EngineContract.setNickname,
        EngineContract.refreshPairingCode,
        EngineContract.submitPairingCode,
        EngineContract.acceptPairing,
        EngineContract.rejectPairing,
        EngineContract.archivePairing,
        EngineContract.cancelPairing,
        EngineContract.verifyContact,
        EngineContract.startConversation,
        EngineContract.openConversation,
        EngineContract.closeConversation,
        EngineContract.sendMessage,
        EngineContract.platformFact,
        EngineContract.shutdown,
      ],
      containsAll(const [
        'bootstrap',
        'connect',
        'getIdentity',
        'getProfile',
        'pairingInbox',
        'pairingOutbox',
        'listContacts',
        'listConversations',
        'listMessages',
        'setNickname',
        'refreshPairingCode',
        'submitPairingCode',
        'acceptPairing',
        'rejectPairing',
        'archivePairing',
        'cancelPairing',
        'verifyContact',
        'startConversation',
        'openConversation',
        'closeConversation',
        'sendMessage',
        'platformFact',
        'shutdown',
      ]),
    );
    expect(
      const [
        EngineContract.torStatus,
        EngineContract.runtimeReady,
        EngineContract.profileReady,
        EngineContract.inviteReceived,
        EngineContract.inviteStateChanged,
        EngineContract.messageReceived,
        EngineContract.messageStateChanged,
        EngineContract.conversationReadChanged,
        EngineContract.changed,
        EngineContract.runtimeError,
        EngineContract.runtimeLog,
      ],
      containsAll(const [
        'tor_status',
        'runtime_ready',
        'profile_ready',
        'invite_received',
        'invite_state_changed',
        'message_received',
        'message_state_changed',
        'conversation_read_changed',
        'changed',
        'runtime_error',
        'runtime_log',
      ]),
    );
  });

  test('runtime DTO fixtures parse through Flutter domain models', () async {
    final data = fixture();

    final profile = data.profile;
    expect(profile.installationId, 'installation-alice');
    expect(profile.nickname, 'Alice');

    final contact = data.contact;
    expect(contact.id, 'installation-bob');
    expect(contact.verified, isTrue);

    final conversation = data.conversation;
    expect(conversation.id, 'installation-bob');
    expect(conversation.state, ConversationState.active);
    expect(conversation.unread, 2);
    expect(conversation.lastMessageAt, startsWith('2025-'));

    final message = data.message;
    expect(message.id, 'message-1');
    expect(message.text, 'hello');
    expect(message.state, MessageState.delivered);

    final inviteCode = data.pairingCode;
    expect(inviteCode.code, '12345678');

    final inbox = data.pairingInboxItem;
    expect(inbox.id, 'pairing-1');
    expect(inbox.peer?.nickname, 'Bob');
    expect(inbox.received, isTrue);

    final outbox = data.pairingOutboxItem;
    expect(outbox.id, 'pairing-2');
    expect(outbox.received, isFalse);
  });

  test('runtime event fixtures parse through RuntimeRepository', () async {
    final events = fixture().events
        .map(RuntimePayload.fromMap)
        .map((payload) => payload.runtimeEvent())
        .toList();
    final repository = RuntimeRepository(_StreamRuntime(events));
    final parsed = await repository.events.toList();

    expect(parsed.whereType<TorStatusEvent>(), hasLength(1));
    expect(parsed.whereType<ProfileReadyEvent>(), hasLength(1));
    expect(parsed.whereType<RuntimeErrorEvent>(), hasLength(1));
    expect(parsed.whereType<RuntimeLogEvent>(), hasLength(1));
    expect(
      parsed.whereType<DataChangedEvent>().map((event) => event.type),
      containsAll(const [
        EngineContract.runtimeReady,
        EngineContract.inviteReceived,
        EngineContract.inviteStateChanged,
        EngineContract.messageReceived,
        EngineContract.messageStateChanged,
        EngineContract.conversationReadChanged,
        EngineContract.changed,
      ]),
    );
  });

  test(
    'accepting an invite refreshes inbox, contacts and conversations',
    () async {
      final runtime = _StatefulRuntime();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();
      expect(container.read(appControllerProvider).inbox, hasLength(1));
      expect(container.read(appControllerProvider).contacts, isEmpty);
      expect(container.read(appControllerProvider).conversations, isEmpty);

      await controller.acceptPairing('pairing-1');
      final state = container.read(appControllerProvider);
      expect(state.inbox, isEmpty);
      expect(
        state.contacts.map((item) => item.id),
        contains('installation-bob'),
      );
      expect(
        state.conversations.map((item) => item.contactId),
        contains('installation-bob'),
      );
      expect(state.notice, 'Gotowe.');
      expect(state.error, isEmpty);
    },
  );

  test('starting a conversation refreshes the conversation list', () async {
    final runtime = _StatefulRuntime()..acceptPairingImmediately();
    final container = ProviderContainer(
      overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
    );
    addTearDown(container.dispose);

    final controller = container.read(appControllerProvider.notifier);
    await controller.initialize();
    await controller.openOrStartConversation(
      container.read(appControllerProvider).contacts.single,
    );

    final state = container.read(appControllerProvider);
    expect(state.selectedConversationId, 'installation-bob');
    expect(state.destination, MainDestination.chats);
    expect(state.conversations, isNotEmpty);
    expect(state.action, isEmpty);
  });

  test(
    'controller happy path covers invite, contact, chat and queued message',
    () async {
      final runtime = _StatefulRuntime();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();

      await controller.submitPairingCode('87654321');
      expect(
        container.read(appControllerProvider).outbox.single.status,
        InviteState.pending,
      );
      expect(
        container.read(appControllerProvider).notice,
        contains('Zaproszenie'),
      );

      await controller.acceptPairing('pairing-1');
      var state = container.read(appControllerProvider);
      expect(state.contacts.single.id, 'installation-bob');
      expect(state.conversations.single.contactId, 'installation-bob');

      await controller.verifyContact('installation-bob');
      await controller.openOrStartConversation(state.contacts.single);
      await controller.sendMessage('hello Bob');

      state = container.read(appControllerProvider);
      expect(state.selectedConversationId, 'installation-bob');
      expect(state.messages.single.text, 'hello Bob');
      expect(state.messages.single.state, MessageState.queued);
      expect(state.error, isEmpty);
    },
  );

  test(
    'controller blocks relay actions until Tor status is connected',
    () async {
      final runtime = _StatefulRuntime();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();
      runtime.emitTorStatus(
        phase: 'connecting',
        label: 'Łączenie z relayem onion',
      );
      await Future<void>.delayed(Duration.zero);

      await controller.submitPairingCode('87654321');

      final state = container.read(appControllerProvider);
      expect(runtime.submitPairingCalls, 0);
      expect(state.outbox, isEmpty);
      expect(state.error, contains('Poczekaj na zielony pasek'));
    },
  );

  test(
    'message_received event refreshes selected conversation messages',
    () async {
      final runtime = _StatefulRuntime()..acceptPairingImmediately();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();
      await controller.openConversation('installation-bob');
      expect(container.read(appControllerProvider).messages, isEmpty);

      runtime.receiveRemoteMessage('installation-bob', 'hello from Bob');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(appControllerProvider);
      expect(
        state.messages.map((item) => item.text),
        contains('hello from Bob'),
      );
      expect(state.conversations.single.unread, 1);
    },
  );

  test('opening a conversation refreshes unread counters', () async {
    final runtime = _StatefulRuntime()
      ..acceptPairingImmediately()
      ..receiveRemoteMessage('installation-bob', 'hello from Bob');
    final container = ProviderContainer(
      overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
    );
    addTearDown(container.dispose);

    final controller = container.read(appControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(appControllerProvider).conversations.single.unread,
      1,
    );

    await controller.openConversation('installation-bob');
    expect(
      container.read(appControllerProvider).conversations.single.unread,
      0,
    );
  });

  test('conversation state is preserved from runtime payload', () {
    final conversation = ConversationSummary.fromMap(const {
      'id': 'conversation-1',
      'contactInstallationId': 'alice-installation',
      'status': 'ACTIVE',
      'unreadCount': 0,
    });
    expect(conversation.state, ConversationState.active);
  });

  test(
    'conversation accepts canonical pending and rejects legacy new state',
    () {
      final canonical = ConversationSummary.fromMap(const {
        'id': 'conversation-1',
        'contactInstallationId': 'alice-installation',
        'status': 'PENDING',
        'unreadCount': 0,
      });
      expect(canonical.state, ConversationState.pending);
      expect(
        () => ConversationSummary.fromMap(const {
          'id': 'conversation-2',
          'contactInstallationId': 'bob-installation',
          'status': 'NEW',
          'unreadCount': 0,
        }),
        throwsFormatException,
      );
    },
  );

  test('pairing request accepts seconds-based expiry payload', () {
    final request = PairingItem.fromMap(const {
      'pairing_id': 'pairing-1',
      'expires_at': 1,
      'state': 'PENDING',
    });
    expect(request.id, 'pairing-1');
    expect(request.expiresAt, 1);
    expect(request.status, InviteState.pending);
  });

  test('pairing payload preserves canonical terminal states', () {
    for (final state in const [
      InviteState.accepted,
      InviteState.rejected,
      InviteState.completed,
      InviteState.archived,
      InviteState.cancelled,
    ]) {
      final request = PairingItem.fromMap({
        'pairingId': 'pairing-$state',
        'expiresAt': 1,
        'state': state.wireValue,
      });
      expect(request.status, state);
    }
  });

  test('active invite count ignores terminal inbox records', () {
    final state = AppState(
      inbox: [
        PairingItem.fromMap(const {
          'pairingId': 'pending',
          'state': 'PENDING',
          'sender': {'nickname': 'Bob'},
        }),
        PairingItem.fromMap(const {
          'pairingId': 'accepted',
          'state': 'ACCEPTED',
          'sender': {'nickname': 'Bob'},
        }),
        PairingItem.fromMap(const {
          'pairingId': 'expired',
          'state': 'EXPIRED',
          'sender': {'nickname': 'Bob'},
        }),
      ],
    );

    expect(state.activeInviteCount, 1);
  });

  test('runtime repository exposes v2 data-change event names', () async {
    final repository = RuntimeRepository(
      _EventRuntime(const DataChangedEvent('invite_state_changed')),
    );
    final event = await repository.events.first;
    expect(event, isA<DataChangedEvent>());
    expect((event as DataChangedEvent).type, 'invite_state_changed');
  });

  test('runtime repository preserves canonical message state events', () async {
    final repository = RuntimeRepository(
      _EventRuntime(const DataChangedEvent('message_state_changed')),
    );
    final event = await repository.events.first;
    expect(event, isA<DataChangedEvent>());
    expect((event as DataChangedEvent).type, 'message_state_changed');
  });

  test(
    'message accepts the Unix milliseconds timestamp returned by both runtimes',
    () {
      final message = ChatMessage.fromMap(const {
        'id': 'message-1',
        'body': 'hello',
        'outgoing': false,
        'state': MessageState.delivered,
        'createdAt': 1760000000000,
      });
      expect(message.createdAt, startsWith('2025-'));
    },
  );

  test('message preserves canonical queue and delivery states', () {
    for (final state in const [
      MessageState.queued,
      MessageState.sending,
      MessageState.sent,
      MessageState.delivered,
      MessageState.failed,
    ]) {
      final message = ChatMessage.fromMap({
        'id': 'message-$state',
        'body': 'hello',
        'outgoing': true,
        'state': state.wireValue,
        'createdAt': 1760000000000,
      });
      expect(message.state, state);
    }
  });

  testWidgets('contact tap invokes conversation callback', (tester) async {
    var selected = false;
    final search = TextEditingController();
    addTearDown(search.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsView(
            saved: [_contact()],
            search: search,
            onSearch: () {},
            onSelect: (_) => selected = true,
            onScanInvite: () {},
            onShowInvite: () {},
            fingerprint: 'SELF',
            ownInvite: '12345678',
            error: '',
            notice: '',
            busy: false,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alice'));
    expect(selected, isTrue);
  });

  testWidgets('inbox renders pending pairing actions', (tester) async {
    var accepted = false;
    final request = ContactRequest(
      id: 'pairing-1',
      peer: _contact(),
      status: InviteState.pending,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxView(
            inbox: [request],
            outbox: const [],
            onAccept: (_) => accepted = true,
            onReject: (_) {},
            onArchive: (_) {},
            onCancel: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('@Alice'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.check));
    expect(accepted, isTrue);
  });

  testWidgets('inbox renders terminal invites as archiveable records', (
    tester,
  ) async {
    var archived = false;
    final request = ContactRequest(
      id: 'pairing-1',
      peer: _contact(),
      status: InviteState.completed,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxView(
            inbox: [request],
            outbox: const [],
            onAccept: (_) {},
            onReject: (_) {},
            onArchive: (_) => archived = true,
            onCancel: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('Zakończone'), findsOneWidget);
    expect(find.text('Archiwizuj'), findsOneWidget);
    await tester.tap(find.text('Archiwizuj'));
    expect(archived, isTrue);
  });

  testWidgets('inbox does not offer archive action for archived invites', (
    tester,
  ) async {
    final request = ContactRequest(
      id: 'pairing-1',
      peer: _contact(),
      status: InviteState.archived,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxView(
            inbox: [request],
            outbox: const [],
            onAccept: (_) {},
            onReject: (_) {},
            onArchive: (_) {},
            onCancel: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Zarchiwizowane'), findsOneWidget);
    expect(find.text('Archiwizuj'), findsNothing);
  });

  testWidgets(
    'outbox shows sent invite state and cancel action while pending',
    (tester) async {
      var cancelled = false;
      final request = PairingItem.fromMap(const {
        'pairingId': 'pairing-out',
        'expiresAt': 1760000060,
        'state': 'PENDING',
        'received': false,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InboxView(
              inbox: const [],
              outbox: [request],
              onAccept: (_) {},
              onReject: (_) {},
              onArchive: (_) {},
              onCancel: (_) => cancelled = true,
            ),
          ),
        ),
      );

      expect(find.text('Wysłane zaproszenie'), findsOneWidget);
      expect(find.textContaining('Oczekuje na decyzję'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cancel_outlined));
      expect(cancelled, isTrue);
    },
  );

  testWidgets('action strip renders active operation labels', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ActionStatusStrip(action: 'submitPairing')),
      ),
    );

    expect(find.text('Wysyłanie zaproszenia…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('pairing code dialog groups digits and shows readable timer', (
    tester,
  ) async {
    final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingCodeDialog(
          initialCode: '12345678',
          initialExpiresAt: expiresAt,
          refresh: () async => null,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('1234 5678'), findsOneWidget);
    expect(find.textContaining('Ważny jeszcze 1:'), findsOneWidget);
  });

  testWidgets('pairing code dialog shows busy indication while refreshing', (
    tester,
  ) async {
    final completer = Completer<InviteCode?>();
    final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingCodeDialog(
          initialCode: '12345678',
          initialExpiresAt: expiresAt,
          refresh: () => completer.future,
          onChanged: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Odśwież kod'));
    await tester.pump();

    expect(find.text('Odświeżanie kodu…'), findsOneWidget);
    expect(
      tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .any((indicator) => indicator.value == null),
      isTrue,
    );

    completer.complete(
      InviteCode(
        code: '87654321',
        expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('8765 4321'), findsOneWidget);
  });

  testWidgets('desktop inbox tab shows badge only for active invites', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopRail(
            tab: MobileTab.inbox,
            nickname: 'Alice',
            unreadTotal: 0,
            inboxTotal: 0,
            onTab: (_) {},
            onAccount: () {},
            onSettings: () {},
          ),
        ),
      ),
    );
    expect(find.byType(Badge), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopRail(
            tab: MobileTab.inbox,
            nickname: 'Alice',
            unreadTotal: 0,
            inboxTotal: 2,
            onTab: (_) {},
            onAccount: () {},
            onSettings: () {},
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.byType(CounterBadge), findsOneWidget);
  });

  testWidgets('message bubbles show timestamps for both directions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(
                message: ChatMessage.fromMap(const {
                  'id': 'incoming',
                  'body': 'hello',
                  'outgoing': false,
                  'state': MessageState.delivered,
                  'createdAt': 1760000000000,
                }),
              ),
              MessageBubble(
                message: ChatMessage.fromMap(const {
                  'id': 'outgoing',
                  'body': 'hi',
                  'outgoing': true,
                  'state': MessageState.queued,
                  'createdAt': 1760000000000,
                }),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('hello'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
    expect(find.textContaining('w kolejce'), findsOneWidget);
    expect(find.text('--:--'), findsNothing);
  });

  testWidgets('chat list inserts a day separator between dates', (
    tester,
  ) async {
    final first = 1760000000000;
    final second = 1760086400000;
    final expectedDay = _dayLabel(first);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatsView(
            selected: _contact(),
            contacts: [_contact()],
            conversations: const [],
            messages: [
              ChatMessage.fromMap({
                'id': 'message-1',
                'body': 'first',
                'outgoing': false,
                'state': MessageState.delivered,
                'createdAt': first,
              }),
              ChatMessage.fromMap({
                'id': 'message-2',
                'body': 'second',
                'outgoing': true,
                'state': MessageState.sent,
                'createdAt': second,
              }),
            ],
            composer: TextEditingController(),
            onOpenConversation: (_) {},
            onSend: () {},
            onVerifyContact: (_) {},
            onBack: () {},
            error: '',
            notice: '',
            canSend: false,
          ),
        ),
      ),
    );

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.text(expectedDay), findsOneWidget);
  });

  testWidgets('desktop fallback accepts only an eight digit invite code', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ManualInviteCodePage()));

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Wyślij zaproszenie'));
    await tester.pump();
    expect(find.text('Kod musi zawierać dokładnie 8 cyfr.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1234 5678');
    await tester.tap(find.text('Wyślij zaproszenie'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualInviteCodePage), findsNothing);
  });
}

String _dayLabel(int millisecondsSinceEpoch) {
  final value = DateTime.fromMillisecondsSinceEpoch(
    millisecondsSinceEpoch,
  ).toLocal();
  const weekday = [
    'poniedziałek',
    'wtorek',
    'środa',
    'czwartek',
    'piątek',
    'sobota',
    'niedziela',
  ];
  const month = [
    'stycznia',
    'lutego',
    'marca',
    'kwietnia',
    'maja',
    'czerwca',
    'lipca',
    'sierpnia',
    'września',
    'października',
    'listopada',
    'grudnia',
  ];
  return '${weekday[value.weekday - 1]}, ${value.day} ${month[value.month - 1]} ${value.year}';
}

class _EventRuntime implements ClientRuntime {
  _EventRuntime(this.event);
  final RuntimeEvent event;

  @override
  Stream<RuntimeEvent> get events => Stream.value(event);

  @override
  Future<void> closeConversation() async {}

  @override
  Future<bool> connect() async => true;

  @override
  Future<List<ContactRecord>> contacts() async => const [];

  @override
  Future<List<ConversationSummary>> conversations() async => const [];

  @override
  Future<RuntimeIdentity?> identity() async => const RuntimeIdentity();

  @override
  Future<List<ChatMessage>> messages(String id) async => const [];

  @override
  Future<void> openConversation(String id) async {}

  @override
  Future<List<PairingItem>> pairingInbox() async => const [];

  @override
  Future<List<PairingItem>> pairingOutbox() async => const [];

  @override
  Future<void> acceptPairing(String pairingId) async {}

  @override
  Future<void> rejectPairing(String pairingId) async {}

  @override
  Future<void> cancelPairing(String pairingId) async {}

  @override
  Future<void> archivePairing(String pairingId) async {}

  @override
  Future<RuntimeProfile?> profile() async => const RuntimeProfile();

  @override
  Future<InviteCode?> refreshPairingCode() async =>
      const InviteCode(code: '', expiresAt: 0);

  @override
  Future<void> sendMessage(String id, String text) async {}

  @override
  Future<RuntimeProfile> setNickname(String nickname) async =>
      const RuntimeProfile();

  @override
  Future<void> startConversation(String contactId) async {}

  @override
  Future<PairingItem> submitPairingCode(String code) async =>
      const PairingItem(id: '', status: InviteState.pending);

  @override
  Future<void> verifyContact(String installationId) async {}

  @override
  Future<void> updateAppVisibility(bool foreground) async {}
}

class _StreamRuntime extends _EventRuntime {
  _StreamRuntime(this.values) : super(const RuntimeLogEvent('stream'));
  final List<RuntimeEvent> values;

  @override
  Stream<RuntimeEvent> get events => Stream.fromIterable(values);
}

class _StatefulRuntime implements ClientRuntime {
  final _events = StreamController<RuntimeEvent>.broadcast();
  final _bob = const ContactRecord(
    id: 'installation-bob',
    nickname: 'Bob',
    fingerprint: 'bb11 cc22 dd33 ee44 ff55 0066 1122 3344',
    publicKey: 'bob-public-key',
    verified: false,
  );
  final _profile = const RuntimeProfile(
    installationId: 'installation-alice',
    nickname: 'Alice',
    publicKey: 'alice-public-key',
    fingerprint: 'aa11 bb22 cc33 dd44 ee55 ff66 0011 2233',
  );

  var _contacts = <ContactRecord>[];
  var _conversations = <ConversationSummary>[];
  final _messages = <String, List<ChatMessage>>{};
  var _inbox = <PairingItem>[];
  var _outbox = <PairingItem>[];
  var submitPairingCalls = 0;

  _StatefulRuntime() {
    _inbox = [
      PairingItem(
        id: 'pairing-1',
        peer: _bob,
        status: InviteState.pending,
        availableActions: const [
          PairingAvailableAction.accept,
          PairingAvailableAction.reject,
        ],
        expiresAt: 1760000060,
      ),
    ];
  }

  void acceptPairingImmediately() {
    _inbox.clear();
    _contacts = [_bob];
    _conversations = [
      ConversationSummary(
        id: 'installation-bob',
        contactId: 'installation-bob',
        preview: 'Nowa rozmowa',
        unread: 0,
        state: ConversationState.active,
        lastMessageAt: '',
      ),
    ];
  }

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  void emitTorStatus({required String phase, required String label}) {
    _events.add(
      TorStatusEvent(
        RuntimeTorStatus(
          phase: TransportPhase.fromValue(phase),
          label: label,
          detail: '',
          progress: null,
          latencyMs: null,
          retryAttempt: 0,
        ),
      ),
    );
  }

  @override
  Future<bool> connect() async => true;

  @override
  Future<RuntimeIdentity?> identity() async => RuntimeIdentity(
    installationId: _profile.installationId,
    fingerprint: _profile.fingerprint,
    publicKey: _profile.publicKey,
  );

  @override
  Future<RuntimeProfile?> profile() async => _profile;

  @override
  Future<InviteCode?> refreshPairingCode() async =>
      const InviteCode(code: '12345678', expiresAt: 1760000060);

  @override
  Future<RuntimeProfile> setNickname(String nickname) async => RuntimeProfile(
    installationId: _profile.installationId,
    nickname: nickname,
    publicKey: _profile.publicKey,
    fingerprint: _profile.fingerprint,
  );

  @override
  Future<PairingItem> submitPairingCode(String code) async {
    submitPairingCalls += 1;
    final value = const PairingItem(
      id: 'pairing-out',
      status: InviteState.pending,
      availableActions: [PairingAvailableAction.cancel],
      expiresAt: 1760000060,
      received: false,
    );
    _outbox = [value];
    return value;
  }

  @override
  Future<List<PairingItem>> pairingInbox() async =>
      List<PairingItem>.from(_inbox);

  @override
  Future<List<PairingItem>> pairingOutbox() async =>
      List<PairingItem>.from(_outbox);

  @override
  Future<void> acceptPairing(String pairingId) async {
    if (!_inbox.any((item) => item.id == pairingId)) {
      throw StateError('pairing does not exist');
    }
    acceptPairingImmediately();
  }

  @override
  Future<void> rejectPairing(String pairingId) async {
    _inbox = _inbox.where((item) => item.id != pairingId).toList();
  }

  @override
  Future<void> cancelPairing(String pairingId) async {
    _outbox = _outbox.where((item) => item.id != pairingId).toList();
  }

  @override
  Future<void> archivePairing(String pairingId) async {
    _inbox = _inbox.where((item) => item.id != pairingId).toList();
    _outbox = _outbox.where((item) => item.id != pairingId).toList();
  }

  @override
  Future<void> verifyContact(String installationId) async {
    _contacts = _contacts
        .map(
          (item) => item.id == installationId
              ? ContactRecord(
                  id: item.id,
                  nickname: item.nickname,
                  fingerprint: item.fingerprint,
                  publicKey: item.publicKey,
                  verified: true,
                )
              : item,
        )
        .toList();
  }

  @override
  Future<List<ContactRecord>> contacts() async =>
      List<ContactRecord>.from(_contacts);

  @override
  Future<List<ConversationSummary>> conversations() async =>
      List<ConversationSummary>.from(_conversations);

  @override
  Future<List<ChatMessage>> messages(String id) async =>
      List<ChatMessage>.from(_messages[id] ?? const []);

  @override
  Future<void> openConversation(String id) async {
    _conversations = _conversations
        .map(
          (item) => item.id == id
              ? ConversationSummary(
                  id: item.id,
                  contactId: item.contactId,
                  preview: item.preview,
                  unread: 0,
                  state: item.state,
                  lastMessageAt: item.lastMessageAt,
                )
              : item,
        )
        .toList();
  }

  @override
  Future<void> closeConversation() async {}

  @override
  Future<void> startConversation(String contactId) async {
    if (!_contacts.any((item) => item.id == contactId)) {
      throw StateError('contact does not exist');
    }
    _conversations = [
      ConversationSummary(
        id: contactId,
        contactId: contactId,
        preview: 'Nowa rozmowa',
        unread: 0,
        state: ConversationState.active,
        lastMessageAt: '',
      ),
    ];
  }

  @override
  Future<void> sendMessage(String id, String text) async {
    final current = _messages[id] ?? const [];
    _messages[id] = [
      ...current,
      ChatMessage(
        id: 'message-${current.length + 1}',
        text: text,
        outgoing: true,
        state: MessageState.queued,
        createdAt: '2025-10-09T00:00:00.000Z',
      ),
    ];
  }

  void receiveRemoteMessage(String conversationId, String text) {
    final current = _messages[conversationId] ?? const [];
    _messages[conversationId] = [
      ...current,
      ChatMessage(
        id: 'remote-${current.length + 1}',
        text: text,
        outgoing: false,
        state: MessageState.delivered,
        createdAt: '2025-10-09T00:00:00.000Z',
      ),
    ];
    _conversations = _conversations
        .map(
          (item) => item.id == conversationId
              ? ConversationSummary(
                  id: item.id,
                  contactId: item.contactId,
                  preview: text,
                  unread: item.unread + 1,
                  state: item.state,
                  lastMessageAt: '2025-10-09T00:00:00.000Z',
                )
              : item,
        )
        .toList();
    _events.add(DataChangedEvent(EngineContract.messageReceived));
  }

  @override
  Future<void> updateAppVisibility(bool foreground) async {}
}
