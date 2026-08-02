import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/app/app_controller.dart';
import 'package:torchat_mobile/core/runtime/runtime_contract.dart';
import 'package:torchat_mobile/core/runtime/runtime_repository.dart';
import 'package:torchat_mobile/features/chats/chats_view.dart';
import 'package:torchat_mobile/features/contacts/contacts_view.dart';
import 'package:torchat_mobile/features/invites/invite_scanner.dart';
import 'package:torchat_mobile/features/onboarding/onboarding_views.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';
import 'package:torchat_mobile/core/runtime/runtime_payload.dart';
import 'package:torchat_mobile/shared/widgets/action_tile.dart';
import 'package:torchat_mobile/features/shell/desktop/desktop_workspace.dart';

final _statefulRuntimes = <_StatefulRuntime>[];

ContactRecord _contact() => const ContactRecord(
  id: 'alice-installation',
  nickname: 'Alice',
  fingerprint: 'AA:BB',
  publicKey: 'public-key',
  verified: false,
);

void main() {
  setUp(ApplicationStateStore.shared.clear);
  tearDown(() async {
    for (final runtime in _statefulRuntimes) {
      await runtime.dispose();
    }
    _statefulRuntimes.clear();
    ApplicationStateStore.shared.clear();
  });
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
        EngineContract.retryMessage,
        EngineContract.deleteMessageLocal,
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
        'retryMessage',
        'deleteMessageLocal',
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
      unawaited(controller.initialize());
      await Future<void>.delayed(const Duration(milliseconds: 100));
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
    runtime.clearConversations();
    await controller.openOrStartConversation(
      container.read(appControllerProvider).contacts.single,
    );

    final state = container.read(appControllerProvider);
    expect(state.selectedConversationId, 'installation-bob');
    expect(state.destination, MainDestination.chats);
    expect(state.conversations, isNotEmpty);
    expect(state.action, isEmpty);
    expect(runtime.startConversationCalls, 1);
    expect(runtime.openConversationCalls, 1);
  });

  test(
    'auto-paired Torka starts a conversation even when the contact still has a fallback nickname',
    () async {
      debugTorkaPairingCodeOverride = '42424242';
      addTearDown(() {
        debugTorkaPairingCodeOverride = null;
      });

      final runtime = _StatefulRuntime();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      unawaited(controller.initialize());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(runtime.submitPairingCalls, 1);
      expect(container.read(appControllerProvider).conversations, isEmpty);

      runtime.publishTorkaContactWithoutConversation();
      await Future<void>.delayed(Duration.zero);
      await controller.refreshData();
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (container
            .read(appControllerProvider)
            .conversations
            .any(
              (conversation) => conversation.contactId == 'installation-torka',
            )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final state = container.read(appControllerProvider);
      expect(state.contacts.single.id, 'installation-torka');
      expect(
        state.conversations.map((item) => item.contactId),
        contains('installation-torka'),
      );
    },
  );

  test(
    'existing fallback-named Torka contact is still recognized after controller restart',
    () async {
      debugTorkaPairingCodeOverride = '42424242';
      addTearDown(() {
        debugTorkaPairingCodeOverride = null;
      });

      final runtime = _StatefulRuntime();
      runtime.publishTorkaContactWithoutConversation();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();
      await controller.refreshData();

      final state = container.read(appControllerProvider);
      expect(runtime.submitPairingCalls, 0);
      expect(state.contacts.single.id, 'installation-torka');
      expect(
        state.conversations.map((item) => item.contactId),
        contains('installation-torka'),
      );
    },
  );

  test(
    'startup stays on boot screen until the local P2P endpoint is ready',
    () async {
      final runtime = _StatefulRuntime(emitPeerReady: false);
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      unawaited(controller.initialize());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(appControllerProvider);
      expect(state.screen, ControllerScreen.boot);
      expect(state.transport.phase, TransportPhase.connected);
      expect(state.peerServerStatus, PeerServerStatus.starting);
      expect(
        state.startupSteps
            .firstWhere((step) => step.kind == StartupStepKind.communication)
            .state,
        StartupStepState.pending,
      );
    },
  );

  test(
    'manual pairing cancels the blocking Torka request before retrying',
    () async {
      debugTorkaPairingCodeOverride = '42424242';
      addTearDown(() {
        debugTorkaPairingCodeOverride = null;
      });

      final runtime = _StatefulRuntime();
      runtime.seedOutgoingTorkaRequest();
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();
      runtime.resetSubmitPairingMetrics();

      await controller.submitPairingCode('87654321');

      final state = container.read(appControllerProvider);
      expect(runtime.cancelPairingCalls, ['pairing-out']);
      expect(runtime.lastSubmittedPairingCode, '87654321');
      expect(runtime.submitPairingCalls, 1);
      expect(state.notice, contains('Zaproszenie wysłane'));
    },
  );

  test(
    'Torka watchdog materializes the contact even when no runtime event arrives',
    () async {
      debugTorkaPairingCodeOverride = '42424242';
      debugTorkaWatchdogIntervalOverride = const Duration(milliseconds: 5);
      debugTorkaWatchdogMaxAttemptsOverride = 20;
      addTearDown(() {
        debugTorkaPairingCodeOverride = null;
        debugTorkaWatchdogIntervalOverride = null;
        debugTorkaWatchdogMaxAttemptsOverride = null;
      });

      final runtime = _StatefulRuntime()
        ..publishSilentTorkaContactWithoutConversationAfter(
          const Duration(milliseconds: 15),
        );
      final container = ProviderContainer(
        overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);

      final controller = container.read(appControllerProvider.notifier);
      await controller.initialize();

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final state = container.read(appControllerProvider);
      expect(
        state.contacts.map((contact) => contact.id),
        contains('installation-torka'),
      );
      expect(
        state.conversations.map((conversation) => conversation.contactId),
        contains('installation-torka'),
      );
    },
  );

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

  test('controller localizes an expired pairing code error', () async {
    final runtime = _StatefulRuntime()
      ..submitPairingError = PlatformException(
        code: 'RUNTIME',
        message: 'pairing code expired or invalid',
      );
    final container = ProviderContainer(
      overrides: [clientRuntimeProvider.overrideWithValue(runtime)],
    );
    addTearDown(container.dispose);

    final controller = container.read(appControllerProvider.notifier);
    await controller.initialize();
    await controller.submitPairingCode('87654321');

    final state = container.read(appControllerProvider);
    expect(state.error, contains('nieprawidłowy albo wygasł'));
    expect(state.error, isNot(contains('relay transport error')));
  });

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
      for (var attempt = 0; attempt < 30; attempt += 1) {
        if (container.read(appControllerProvider).messages.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final state = container.read(appControllerProvider);
      expect(
        state.messages.map((item) => item.text),
        contains('hello from Bob'),
      );
      expect(state.conversations, isNotEmpty);
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
    await controller.refreshData();
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
    'conversation accepts canonical pending and rejects obsolete new state',
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
      'pairingId': 'pairing-1',
      'expiresAt': 1,
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
    ApplicationStateStore.shared.setPairing([
      PairingItem.fromMap(const {
        'pairingId': 'pending',
        'state': 'PENDING',
        'sender': {'nickname': 'Bob'},
        'availableActions': ['ACCEPT', 'REJECT'],
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
    ], const []);
    final state = AppState();

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
        home: ProviderScope(
          child: Scaffold(
            body: ContactsView(
              saved: [_contact()],
              search: search,
              onSearch: () {},
              onSelect: (_) => selected = true,
              onScanInvite: () {},
              onShowInvite: () {},
              onUpdateContactSettings: (_, _, _, _, _) async {},
              fingerprint: 'SELF',
              ownInvite: '12345678',
              error: '',
              notice: '',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alice'));
    expect(selected, isTrue);
  });

  /* testWidgets('inbox renders pending pairing actions', (tester) async {
    var accepted = false;
    final request = ContactRequest(
      id: 'pairing-1',
      peer: _contact(),
      status: InviteState.pending,
      availableActions: const [
        PairingAvailableAction.accept,
        PairingAvailableAction.reject,
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemovedInboxView(
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
    await tester.tap(find.byType(FilledButton).first);
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
      availableActions: const [PairingAvailableAction.archive],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemovedInboxView(
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
          body: RemovedInboxView(
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
        'availableActions': ['CANCEL'],
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemovedInboxView(
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

      await tester.tap(find.text('Outbox (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Wysłane zaproszenie'), findsOneWidget);
      expect(find.textContaining('Oczekuje na decyzję'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cancel_outlined));
      expect(cancelled, isTrue);
    },
  ); */

  testWidgets('action strip renders active operation labels', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ActionTile(
            title: 'Wyślij zaproszenie',
            subtitle: '',
            busy: true,
            busyLabel: 'Wysyłanie zaproszenia…',
          ),
        ),
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

    await tester.ensureVisible(find.text('Odśwież kod'));
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
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('8765 4321'), findsOneWidget);
  });

  testWidgets('pairing code dialog shows a timed contact approval', (
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
          checkRequest: () async => PairingItem(
            id: 'pairing-approval',
            status: InviteState.pending,
            peer: _contact(),
            expiresAt: expiresAt,
          ),
          onAccept: (_) async => true,
          onReject: (_) async {},
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('AA:BB'), findsNothing);
    expect(
      find.textContaining('Zaproszenie oczekuje na Twoją decyzję'),
      findsOneWidget,
    );
    expect(find.text('Akceptuj'), findsOneWidget);
    expect(find.text('Odrzuć'), findsOneWidget);
    expect(find.text('1234 5678'), findsNothing);

    await tester.tap(find.text('Akceptuj'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('incoming pairing uses the detailed contact decision model', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncomingPairingDialog(
            request: PairingItem(
              id: 'incoming-pairing',
              status: InviteState.pending,
              peer: _contact(),
            ),
            onAccept: () async {},
            onReject: () async {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Szczegóły bezpieczeństwa'), findsOneWidget);
    expect(find.text('Akceptuj'), findsOneWidget);
    expect(find.text('Odrzuć'), findsOneWidget);
  });

  testWidgets('desktop navigation no longer exposes inbox', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopWorkspace(
            tab: MobileTab.contacts,
            nickname: 'Alice',
            contacts: const [],
            conversations: const [],
            selectedConversation: null,
            selectedContact: null,
            onlineContacts: const {},
            content: const SizedBox.shrink(),
            onTab: (_) {},
            onOpenConversation: (_) {},
            onStartConversation: (_) {},
            onVerifyContact: (_) {},
            onBack: () {},
            onAccount: () {},
            onSettings: () {},
          ),
        ),
      ),
    );

    expect(find.text('Inbox'), findsNothing);
    expect(find.text('Czaty'), findsOneWidget);
    expect(find.text('Kontakty'), findsWidgets);
  });

  testWidgets('message bubbles show timestamps for both directions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderScope(
          child: Scaffold(
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
                  startsGroup: true,
                  endsGroup: true,
                  onDelete: (_) {},
                  onRetry: (_) {},
                  onReply: (_) {},
                ),
                MessageBubble(
                  message: ChatMessage.fromMap(const {
                    'id': 'outgoing',
                    'body': 'hi',
                    'outgoing': true,
                    'state': MessageState.queued,
                    'createdAt': 1760000000000,
                  }),
                  startsGroup: false,
                  endsGroup: true,
                  onDelete: (_) {},
                  onRetry: (_) {},
                  onReply: (_) {},
                ),
              ],
            ),
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
        home: ProviderScope(
          child: Scaffold(
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
              onSend: (_) async {},
              onTypingChanged: (_) {},
              onRetryMessage: (_) {},
              onDeleteMessage: (_) {},
              onVerifyContact: (_) {},
              onBack: () {},
              error: '',
              notice: '',
              canSend: false,
            ),
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
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ManualInviteCodePage())),
    );

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Dodaj kontakt'));
    await tester.pump();
    expect(find.text('Kod musi zawierać dokładnie 8 cyfr.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1234 5678');
    await tester.tap(find.widgetWithText(FilledButton, 'Dodaj kontakt'));
    await tester.pump(const Duration(milliseconds: 500));
    // Without a connected runtime the page remains mounted and exposes the
    // transport error; validation must not falsely report success.
    expect(find.byType(ManualInviteCodePage), findsOneWidget);
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
  Future<StartupReadinessSnapshot> startupReadiness() async =>
      const StartupReadinessSnapshot(
        engineReady: true,
        localDataReady: true,
        torReady: true,
        peerListenerReady: true,
        onionServiceReady: true,
        relayReady: true,
        generation: 1,
        detail: 'test runtime ready',
      );

  @override
  Future<List<ContactRecord>> contacts() async => const [];

  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) async {}

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
  Future<PeerEndpoint?> peerEndpoint() async => null;

  @override
  Future<bool> peerEndpointAvailable() async => false;

  @override
  Future<void> retryPeerConnection(String installationId) async {}

  @override
  Future<void> rotatePeerEndpoint() async {}

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
  }) async => const ContactRecord(
    id: '',
    nickname: '',
    fingerprint: '',
    publicKey: '',
    verified: false,
  );

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
  _StatefulRuntime({this.emitPeerReady = true}) {
    _statefulRuntimes.add(this);
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

  final bool emitPeerReady;
  final _events = StreamController<RuntimeEvent>.broadcast();
  final _bob = const ContactRecord(
    id: 'installation-bob',
    nickname: 'Bob',
    fingerprint: 'bb11 cc22 dd33 ee44 ff55 0066 1122 3344',
    publicKey: 'bob-public-key',
    verified: false,
  );
  final _torka = const ContactRecord(
    id: 'installation-torka',
    nickname: 'peer-torka',
    fingerprint: 'tt11 uu22 vv33 ww44 xx55 0066 1122 3344',
    publicKey: 'torka-public-key',
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
  var startConversationCalls = 0;
  var openConversationCalls = 0;
  String? lastSubmittedPairingCode;
  final cancelPairingCalls = <String>[];
  Object? submitPairingError;

  Future<void> dispose() => _events.close();

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

  void publishTorkaContactWithoutConversation() {
    _contacts = [_torka];
    _conversations = [];
    _events.add(DataChangedEvent(EngineContract.changed));
  }

  void clearConversations() {
    _conversations = [];
  }

  void publishSilentTorkaContactWithoutConversationAfter(Duration delay) {
    Future<void>.delayed(delay, () {
      _contacts = [_torka];
      _conversations = [];
    });
  }

  void seedOutgoingTorkaRequest() {
    _outbox = [
      PairingItem(
        id: 'pairing-out',
        peer: _torka,
        status: InviteState.pending,
        availableActions: const [PairingAvailableAction.cancel],
        expiresAt: 1760000060,
        received: false,
      ),
    ];
  }

  void resetSubmitPairingMetrics() {
    submitPairingCalls = 0;
    lastSubmittedPairingCode = null;
    cancelPairingCalls.clear();
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
  Future<bool> connect() async {
    _events.add(const RuntimeReadyEvent(1));
    emitTorStatus(phase: 'connected', label: 'Połączono');
    for (final component in TransportComponent.values) {
      if (!emitPeerReady && component == TransportComponent.peer) continue;
      _events.add(
        TransportStatusChangedEvent(
          TransportStatusSnapshot(
            component: component,
            state: TransportProbeState.ready,
            detail: 'test ready',
            generation: 1,
          ),
        ),
      );
    }
    if (emitPeerReady) {
      _events.add(
        PeerEndpointChangedEvent(
          contactId: _profile.installationId,
          status: PeerEndpointStatus.verified,
        ),
      );
    }
    return true;
  }

  @override
  Future<StartupReadinessSnapshot> startupReadiness() async =>
      StartupReadinessSnapshot(
        engineReady: true,
        localDataReady: true,
        torReady: true,
        peerListenerReady: emitPeerReady,
        onionServiceReady: emitPeerReady,
        relayReady: true,
        generation: 1,
        detail: 'test runtime ready',
      );

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
    lastSubmittedPairingCode = code;
    final error = submitPairingError;
    if (error != null) throw error;
    final value = PairingItem(
      id: 'pairing-out',
      peer: _torka,
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
  Future<PeerEndpoint?> peerEndpoint() async => null;

  @override
  Future<bool> peerEndpointAvailable() async => emitPeerReady;

  @override
  Future<void> retryPeerConnection(String installationId) async {}

  @override
  Future<void> rotatePeerEndpoint() async {}

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
    cancelPairingCalls.add(pairingId);
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
  }) async => _bob;

  @override
  Future<List<ContactRecord>> contacts() async =>
      List<ContactRecord>.from(_contacts);

  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) async {}

  @override
  Future<List<ConversationSummary>> conversations() async =>
      List<ConversationSummary>.from(_conversations);

  @override
  Future<List<ChatMessage>> messages(String id) async =>
      List<ChatMessage>.from(_messages[id] ?? const []);

  @override
  Future<void> openConversation(String id) async {
    openConversationCalls += 1;
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
    startConversationCalls += 1;
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
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {
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
    _events.add(
      DataChangedEvent(EngineContract.messageReceived, {
        EngineContract.conversationId: conversationId,
      }),
    );
  }

  @override
  Future<void> updateAppVisibility(bool foreground) async {}
}
