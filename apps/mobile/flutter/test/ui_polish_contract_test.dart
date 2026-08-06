import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production UI uses the shared toast host instead of SnackBars', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final offenders = <String>[];
    for (final file in files) {
      if (file.readAsStringSync().contains('showSnackBar')) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('shell uses the unified transport dock without global busy strip', () {
    final shell = File('lib/features/shell/main_shell.dart').readAsStringSync();

    expect(shell, contains('ConnectionStatusLamp('));
    expect(shell, isNot(contains('CockpitStatusBar(')));
    expect(shell, isNot(contains('CompactCockpitStatusBar(')));
    expect(shell, contains('DesktopWorkspace('));
    expect(shell, isNot(contains('ActionStatusStrip')));
  });

  test('desktop workspace is compact and resizable without placeholder tabs', () {
    final workspace = File(
      'lib/platform/desktop/desktop_workspace.dart',
    ).readAsStringSync();
    final sharedShell = File(
      '../../../packages/torchat-flutter-ui/lib/core/presentation/desktop_workspace_shell.dart',
    ).readAsStringSync();
    final splitter = File(
      '../../../packages/torchat-flutter-ui/lib/core/presentation/resizable_split_pane.dart',
    ).readAsStringSync();

    expect(workspace, contains('DesktopWorkspaceShell('));
    expect(sharedShell, contains('ResizableSplitPane('));
    expect(workspace, isNot(contains("'Grupy'")));
    expect(workspace, isNot(contains('Nie mieszamy ich ze zwykłymi czatami')));
    expect(workspace, contains('context.l10n.appTitle'));
    expect(workspace, isNot(contains('PeerServerIndicator')));
    expect(splitter, contains('SystemMouseCursors.resizeColumn'));
    expect(splitter, contains('torchat.desktop.sidebar.width'));
  });

  test('active chat UI has no voice or video controls', () {
    final chat = File(
      'lib/features/chats/release_chat_view.dart',
    ).readAsStringSync();
    final bubble = File(
      'lib/features/chats/message_bubble.dart',
    ).readAsStringSync();

    expect(chat, isNot(contains('Icons.phone')));
    expect(chat, isNot(contains('Icons.videocam')));
    expect(chat, isNot(contains('Icons.video_call')));
    expect(bubble, contains('_BubbleHeader'));
    expect(bubble, contains('_BubbleFooter'));
    expect(bubble, contains('IntrinsicWidth'));
    expect(bubble, contains('BoxConstraints(minWidth: 120, maxWidth: 560)'));
    expect(bubble, contains('MessageState.delivered || MessageState.read'));
  });

  test('new conversations use the canonical runtime projection', () {
    final commands = File(
      'lib/app/application_controller.dart',
    ).readAsStringSync();

    expect(commands, isNot(contains('ConversationSummary(')));
    expect(commands, isNot(contains('ConversationState.pending')));
    expect(
      commands,
      contains('Future<void> openOrStartConversation(ContactRecord contact)'),
    );
    expect(commands, contains('_repository.activateConversation(contact.id)'));
  });

  test('busy surfaces avoid flicker and block their own component', () {
    final busy = File(
      '../../../packages/torchat-flutter-ui/lib/async/busy_surface.dart',
    ).readAsStringSync();

    expect(busy, contains('Duration(milliseconds: 150)'));
    expect(busy, contains('Duration(milliseconds: 300)'));
    expect(busy, contains('AbsorbPointer('));
    expect(busy, contains('AnimatedOpacity('));
    expect(busy, contains('disableAnimations'));
  });
}
