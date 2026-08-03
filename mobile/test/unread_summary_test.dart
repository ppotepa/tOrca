import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/application_state/unread_summary.dart';
import 'package:torchat_mobile/core/models/domain.dart';

ConversationSummary conversation(String id, String contactId, int unread) =>
    ConversationSummary(
      id: id,
      contactId: contactId,
      preview: '',
      unread: unread,
    );

void main() {
  test('navigation counts contacts while rows count unread messages', () {
    final summary = [
      conversation('alice-main', 'alice', 3),
      conversation('alice-secondary', 'alice', 2),
      conversation('bob-main', 'bob', 1),
      conversation('torka-main', 'torka', 0),
    ].unreadSummary;

    expect(summary.contactsWithUnread, 2);
    expect(summary.totalUnreadMessages, 6);
    expect(summary.messagesFor('alice-main'), 3);
    expect(summary.messagesFor('alice-secondary'), 2);
    expect(summary.messagesFor('bob-main'), 1);
    expect(summary.messagesFor('torka-main'), 0);
  });
}
