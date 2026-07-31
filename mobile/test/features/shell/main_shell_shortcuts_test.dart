import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/features/shell/main_shell.dart';

void main() {
  testWidgets('shell exposes navigation and recovery shortcuts', (tester) async {
    var tab = MobileTab.chats;
    var settings = 0;
    var account = 0;
    var reconnect = 0;
    var back = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          tab: tab,
          nickname: 'Alice',
          fingerprint: 'aa bb',
          ownInvite: '',
          status: 'Połączono',
          phase: TransportPhase.connected,
          latencyMs: 10,
          peerServerStatus: PeerServerStatus.ready,
          contacts: const [],
          conversations: const [],
          messages: const [],
          selectedConversation: 'conversation-1',
          selectedContact: null,
          search: TextEditingController(),
          composer: TextEditingController(),
          error: '',
          notice: '',
          action: '',
          onTab: (value) => tab = value,
          onSearch: () {},
          onOpenConversation: (_) {},
          onStartConversation: (_) {},
          onScanInvite: () {},
          onShowInvite: () {},
          onSend: (_) {},
          onTypingChanged: (_) {},
          onRetryMessage: (_) {},
          onDeleteMessage: (_) {},
          onVerifyContact: (_) {},
          onUpdateContactSettings: (_, _, _, _, _) async {},
          onBack: () => back += 1,
          onOpenAccount: () => account += 1,
          onOpenSettings: () => settings += 1,
          onRetryTor: () => reconnect += 1,
          typingContacts: const {},
          onlineContacts: const {},
        ),
      ),
    );
    await tester.pump();

    await _shortcut(tester, LogicalKeyboardKey.digit2, control: true);
    expect(tab, MobileTab.contacts);

    await _shortcut(tester, LogicalKeyboardKey.comma, control: true);
    expect(settings, 1);

    await _shortcut(
      tester,
      LogicalKeyboardKey.keyA,
      control: true,
      shift: true,
    );
    expect(account, 1);

    await _shortcut(
      tester,
      LogicalKeyboardKey.keyR,
      control: true,
      shift: true,
    );
    expect(reconnect, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(back, 1);
  });
}

Future<void> _shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}
