import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/runtime/message_paging.dart';
import 'package:torchat_mobile/features/chats/release_chat_view.dart';

void main() {
  const contact = ContactRecord(
    id: 'peer',
    nickname: 'Ala',
    fingerprint: 'fingerprint',
    publicKey: 'public-key',
    verified: true,
  );
  const conversation = ConversationSummary(
    id: 'conversation',
    contactId: 'peer',
    preview: 'wiadomość',
    unread: 0,
    state: ConversationState.active,
  );

  ChatMessage message(int index) => ChatMessage(
    id: 'message-$index',
    text: 'wiadomość $index',
    outgoing: index.isOdd,
    state: MessageState.delivered,
    createdAt: '2026-08-02T12:00:0$index.000Z',
  );

  Widget view(List<ChatMessage> messages, TextEditingController composer) =>
      ProviderScope(
        child: MaterialApp(
          home: SizedBox(
            width: 900,
            height: 900,
            child: ReleaseChatView(
              selected: contact,
              contacts: const [contact],
              conversations: const [conversation],
              messages: messages,
              composer: composer,
              onOpenConversation: (_) {},
              onSend: (_) async {},
              onTypingChanged: (_) {},
              onRetryMessage: (_) {},
              onDeleteMessage: (_) {},
              onLoadOlderMessages: () async =>
                  const OlderMessagesResult(loadedCount: 0, hasMore: false),
              onBack: () {},
              error: '',
              notice: '',
              canSend: true,
            ),
          ),
        ),
      );

  testWidgets('live messages append to an initially one-message conversation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final composer = TextEditingController();

    await tester.pumpWidget(view([message(1)], composer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('wiadomość 1'), findsOneWidget);

    await tester.pumpWidget(
      view([message(1), message(2), message(3)], composer),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('wiadomość 1'), findsOneWidget);
    expect(find.text('wiadomość 2'), findsOneWidget);
    expect(find.text('wiadomość 3'), findsOneWidget);
    composer.dispose();
  });

  testWidgets('compact conversation home keeps the chat list visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final composer = TextEditingController();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SizedBox(
            width: 360,
            height: 760,
            child: ReleaseChatView(
              selected: null,
              contacts: const [contact],
              conversations: const [conversation],
              messages: const [],
              composer: composer,
              onOpenConversation: (_) {},
              onSend: (_) async {},
              onTypingChanged: (_) {},
              onRetryMessage: (_) {},
              onDeleteMessage: (_) {},
              onLoadOlderMessages: () async =>
                  const OlderMessagesResult(loadedCount: 0, hasMore: false),
              onBack: () {},
              error: '',
              notice: '',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ostatnie rozmowy'), findsOneWidget);
    expect(find.text('Ala'), findsOneWidget);
    expect(find.text('wiadomość'), findsOneWidget);
    composer.dispose();
  });
}
