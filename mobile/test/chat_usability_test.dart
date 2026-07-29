import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/features/chats/chats_view.dart';

void main() {
  testWidgets('Enter sends and Shift+Enter inserts a new line', (tester) async {
    final composer = TextEditingController(text: 'Pierwsza linia');
    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatsView(
          selected: const ContactRecord(
            id: 'peer',
            nickname: 'Ala',
            fingerprint: 'abcd',
            publicKey: 'pk',
            verified: true,
          ),
          contacts: const [],
          conversations: const [],
          messages: const [],
          composer: composer,
          onOpenConversation: (_) {},
          onSend: (_) => sent++,
          onTypingChanged: (_) {},
          onRetryMessage: (_) {},
          onDeleteMessage: (_) {},
          onVerifyContact: (_) {},
          onBack: () {},
          error: '',
          notice: '',
          canSend: true,
        ),
      ),
    );

    await tester.tap(find.byType(TextField).last);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);

    composer.selection = TextSelection.collapsed(offset: composer.text.length);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(composer.text, contains('\n'));
    expect(sent, 1);

    composer.dispose();
  });

  testWidgets('reply action sends referenced message id', (tester) async {
    final composer = TextEditingController(text: 'Odpowiedź');
    String? replyId;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatsView(
          selected: const ContactRecord(
            id: 'peer',
            nickname: 'Ala',
            fingerprint: 'abcd',
            publicKey: 'pk',
            verified: true,
          ),
          contacts: const [],
          conversations: const [],
          messages: const [
            ChatMessage(
              id: 'message-1',
              text: 'Pytanie',
              outgoing: false,
              state: MessageState.delivered,
            ),
          ],
          composer: composer,
          onOpenConversation: (_) {},
          onSend: (value) => replyId = value,
          onTypingChanged: (_) {},
          onRetryMessage: (_) {},
          onDeleteMessage: (_) {},
          onVerifyContact: (_) {},
          onBack: () {},
          error: '',
          notice: '',
          canSend: true,
        ),
      ),
    );

    await tester.longPress(find.text('Pytanie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odpowiedz'));
    await tester.pumpAndSettle();
    expect(find.text('Odpowiedź na: Pytanie'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    expect(replyId, 'message-1');
    composer.dispose();
  });

  testWidgets('composer uses the full chat panel width', (tester) async {
    final composer = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatsView(
          selected: const ContactRecord(
            id: 'peer',
            nickname: 'Ala',
            fingerprint: 'abcd',
            publicKey: 'pk',
            verified: true,
          ),
          contacts: const [],
          conversations: const [],
          messages: const [],
          composer: composer,
          onOpenConversation: (_) {},
          onSend: (_) {},
          onTypingChanged: (_) {},
          onRetryMessage: (_) {},
          onDeleteMessage: (_) {},
          onVerifyContact: (_) {},
          onBack: () {},
          error: '',
          notice: '',
          canSend: true,
        ),
      ),
    );

    final fieldRect = tester.getRect(find.byType(TextField).last);
    expect(fieldRect.left, 0);
    expect(
      fieldRect.right,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );
    composer.dispose();
  });
}
