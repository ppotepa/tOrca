import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shell uses the unified transport dock without global busy strip', () {
    final shell = File('lib/features/shell/main_shell.dart').readAsStringSync();

    expect(shell, contains('TransportStatusDock('));
    expect(shell, isNot(contains('CockpitStatusBar(')));
    expect(shell, isNot(contains('CompactCockpitStatusBar(')));
    expect(shell, contains('DesktopWorkspace('));
    expect(shell, isNot(contains('ActionStatusStrip')));
  });

  test('desktop workspace is compact resizable and separates groups', () {
    final workspace = File(
      'lib/features/shell/desktop/desktop_workspace.dart',
    ).readAsStringSync();
    final splitter = File(
      'lib/features/shell/desktop/resizable_split_pane.dart',
    ).readAsStringSync();

    expect(workspace, contains('ResizableSplitPane('));
    expect(workspace, contains("'Grupy'"));
    expect(workspace, contains('Nie mieszamy ich ze zwykłymi czatami'));
    expect(workspace, contains("'TorChat'"));
    expect(workspace, isNot(contains('PeerServerIndicator')));
    expect(splitter, contains('SystemMouseCursors.resizeColumn'));
    expect(splitter, contains('torchat.desktop.sidebar.width'));
  });

  test('active chat UI has no voice or video controls', () {
    final chat = File('lib/features/chats/chats_view.dart').readAsStringSync();

    expect(chat, isNot(contains('Icons.phone')));
    expect(chat, isNot(contains('Icons.videocam')));
    expect(chat, isNot(contains('Icons.video_call')));
    expect(chat, contains('_BubbleHeader'));
    expect(chat, contains('_BubbleFooter'));
    expect(chat, contains('_ComposerDock'));
    expect(chat, contains('BoxConstraints(maxWidth: 1080)'));
    expect(chat, contains('BoxConstraints(maxWidth: 720)'));
    expect(chat, contains("MessageState.read => Icons.done_all"));
  });

  test('new conversations use the canonical runtime projection', () {
    final notificationController = File(
      'lib/app/notification_safe_app_controller.dart',
    ).readAsStringSync();
    final baseController = File(
      'lib/app/app_controller_base.dart',
    ).readAsStringSync();

    expect(notificationController, isNot(contains('ConversationSummary(')));
    expect(
      notificationController,
      isNot(contains('ConversationState.pending')),
    );
    expect(
      notificationController,
      isNot(contains('Future<void> openOrStartConversation')),
    );
    expect(
      baseController,
      contains('_repository.activateConversation(contact.id)'),
    );
  });

  test('busy surfaces avoid flicker and block their own component', () {
    final busy = File('lib/shared/async/busy_surface.dart').readAsStringSync();

    expect(busy, contains('Duration(milliseconds: 150)'));
    expect(busy, contains('Duration(milliseconds: 300)'));
    expect(busy, contains('AbsorbPointer('));
    expect(busy, contains('AnimatedOpacity('));
    expect(busy, contains('disableAnimations'));
  });
}
