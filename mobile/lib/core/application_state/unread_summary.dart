import '../models/domain.dart';

/// Read-only projection of canonical conversation unread counters.
///
/// Navigation counts distinct contacts requiring attention, while a
/// conversation tile displays the number of unread messages in that chat.
final class UnreadSummary {
  UnreadSummary._({
    required this.contactsWithUnread,
    required this.totalUnreadMessages,
    required this.messagesByConversation,
  });

  factory UnreadSummary.fromConversations(
    Iterable<ConversationSummary> conversations,
  ) {
    final contacts = <String>{};
    final messages = <String, int>{};
    var total = 0;
    for (final conversation in conversations) {
      if (conversation.unread <= 0) continue;
      contacts.add(conversation.contactId);
      messages[conversation.id] = conversation.unread;
      total += conversation.unread;
    }
    return UnreadSummary._(
      contactsWithUnread: contacts.length,
      totalUnreadMessages: total,
      messagesByConversation: Map.unmodifiable(messages),
    );
  }

  final int contactsWithUnread;
  final int totalUnreadMessages;
  final Map<String, int> messagesByConversation;

  int messagesFor(String conversationId) =>
      messagesByConversation[conversationId] ?? 0;
}

extension ConversationUnreadProjection on Iterable<ConversationSummary> {
  UnreadSummary get unreadSummary => UnreadSummary.fromConversations(this);
}
