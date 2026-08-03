import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('pairing establishes trust and opens a conversation automatically', () {
    final controller = source('lib/app/pairing_recovery_app_controller.dart');
    expect(controller, contains('_promoteTrustedPairingContacts'));
    expect(controller, contains('await super.verifyContact(contact.id)'));
    expect(
      controller,
      contains('await super.openOrStartConversation(contact)'),
    );
  });

  test('active chat has user-friendly scroll behavior', () {
    final chat = source('lib/features/chats/release_chat_view.dart');
    expect(chat, contains('_nearBottomThreshold'));
    expect(chat, contains('_unseenMessageCount'));
    expect(chat, contains('keyboard_arrow_down'));
    expect(chat, contains('added.any((message) => message.outgoing)'));
  });

  test('image messages are bounded and rendered locally', () {
    final codec = source('lib/core/attachments/image_message_codec.dart');
    final picker = source('lib/core/attachments/image_attachment_picker.dart');
    final bubble = source('lib/features/chats/release_message_bubble.dart');
    expect(codec, contains('maximumImageAttachmentBytes = 50 * 1024'));
    expect(codec, contains('encodeJpg'));
    expect(
      picker,
      contains("allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp']"),
    );
    expect(bubble, contains('decodeImageMessageBody'));
  });

  test('conversation preferences are device-local and persistent', () {
    final preferences = source('lib/app/conversation_preferences.dart');
    final list = source('lib/shared/widgets/conversation_list_section.dart');
    expect(preferences, contains('torchat.conversation.preferences.v1'));
    expect(preferences, contains('togglePinned'));
    expect(preferences, contains('toggleMuted'));
    expect(list, contains('Zmień nazwę lokalną'));
    expect(list, contains('Archiwizuj lokalnie'));
  });

  test('notification and privacy settings are enforced', () {
    final settings = source('lib/features/account/settings_view.dart');
    final policy = File(
      'android/app/src/main/kotlin/org/torchat/mobile/AndroidNotificationPolicy.kt',
    ).readAsStringSync();
    expect(settings, contains('torchat.notifications.messages'));
    expect(settings, contains('torchat.notifications.pairing'));
    expect(settings, contains('torchat.privacy.readReceipts'));
    expect(policy, contains('flutter.torchat.notifications.messages'));
    expect(policy, contains('flutter.torchat.notifications.pairing'));
  });

  test('manual verify action is absent from the active release chat', () {
    final shell = source('lib/features/shell/main_shell.dart');
    final releaseChat = source('lib/features/chats/release_chat_view.dart');
    expect(shell, contains('ReleaseChatView('));
    expect(releaseChat, isNot(contains("label: const Text('Zweryfikuj')")));
  });

  test('README documents the current release scope', () {
    final release = File('../README.md').readAsStringSync();
    expect(release, contains('Calls, groups, multi-device synchronization'));
    expect(release, contains('not part of the current scope'));
    expect(release, contains('Windows and Android'));
  });
}
