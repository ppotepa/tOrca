import '../../client_runtime.dart';
import '../application_state/application_snapshot.dart';

final class RuntimeLocalSnapshot {
  const RuntimeLocalSnapshot({
    required this.contacts,
    required this.conversations,
    required this.peerEndpointAvailable,
    required this.generation,
  });

  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final bool peerEndpointAvailable;
  final int generation;
}

final class RuntimePairingSnapshot {
  const RuntimePairingSnapshot({
    required this.inbox,
    required this.outbox,
    required this.generation,
  });

  final List<PairingItem> inbox;
  final List<PairingItem> outbox;
  final int generation;
}

final class RuntimeRefreshSnapshot {
  const RuntimeRefreshSnapshot({
    required this.application,
    required this.local,
    this.pairing,
  });

  final ApplicationSnapshot application;
  final RuntimeLocalSnapshot local;
  final RuntimePairingSnapshot? pairing;
}

final class ActivatedConversation {
  const ActivatedConversation({
    required this.conversation,
    required this.messages,
  });

  final ConversationSummary conversation;
  final List<ChatMessage> messages;
}

enum ConversationMessagesPhase { idle, loading, ready, failed }

final class ConversationMessagesLoadState {
  const ConversationMessagesLoadState({
    required this.conversationId,
    required this.phase,
    this.error = '',
  });

  final String conversationId;
  final ConversationMessagesPhase phase;
  final String error;
}
