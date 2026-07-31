import 'dart:async';

class ConversationNavigationIntent {
  const ConversationNavigationIntent({
    required this.conversationId,
    required this.notificationId,
  });

  final String conversationId;
  final String notificationId;
}

class ConversationNavigationIntents {
  ConversationNavigationIntents._();

  static final StreamController<ConversationNavigationIntent> _controller =
      StreamController<ConversationNavigationIntent>.broadcast();

  static Stream<ConversationNavigationIntent> get stream => _controller.stream;

  static void openConversation({
    required String conversationId,
    required String notificationId,
  }) {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    _controller.add(
      ConversationNavigationIntent(
        conversationId: id,
        notificationId: notificationId.trim(),
      ),
    );
  }
}
