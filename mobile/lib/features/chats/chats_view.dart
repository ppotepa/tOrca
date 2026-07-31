import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/busy_surface.dart';
import 'chats_view_legacy.dart' as legacy;

export 'chats_view_legacy.dart' hide ChatsView;

class ChatsView extends ConsumerWidget {
  const ChatsView({
    super.key,
    required this.selected,
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.composer,
    required this.onOpenConversation,
    required this.onSend,
    required this.onTypingChanged,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onVerifyContact,
    required this.onBack,
    required this.error,
    required this.notice,
    this.showConversationListWhenEmpty = true,
    this.canSend = false,
    this.peerTyping = false,
    this.peerOnline = false,
  });

  final ContactRecord? selected;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final TextEditingController composer;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<String?> onSend;
  final ValueChanged<bool> onTypingChanged;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final ValueChanged<String> onVerifyContact;
  final VoidCallback onBack;
  final String error;
  final String notice;
  final bool showConversationListWhenEmpty;
  final bool canSend;
  final bool peerTyping;
  final bool peerOnline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedContactId = selected?.id ?? '';
    var conversationId = '';
    for (final conversation in conversations) {
      if (conversation.contactId == selectedContactId) {
        conversationId = conversation.id;
        break;
      }
    }
    if (conversationId.isEmpty) conversationId = selectedContactId;

    final openState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationOpen(conversationId)),
    );
    final startState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationStart(selectedContactId)),
    );
    final messagesState = ref.watch(
      uiOperationProvider(UiOperationKey.messagesLoad(conversationId)),
    );
    final effectiveState = messagesState.busy
        ? messagesState
        : openState.busy
            ? openState
            : startState;

    return BusySurface(
      state: effectiveState,
      presentation: messages.isEmpty
          ? BusyPresentation.replace
          : BusyPresentation.overlay,
      label: startState.busy
          ? 'Uruchamianie rozmowy…'
          : 'Ładowanie rozmowy…',
      child: legacy.ChatsView(
        selected: selected,
        contacts: contacts,
        conversations: conversations,
        messages: messages,
        composer: composer,
        onOpenConversation: onOpenConversation,
        onSend: onSend,
        onTypingChanged: onTypingChanged,
        onRetryMessage: onRetryMessage,
        onDeleteMessage: onDeleteMessage,
        onVerifyContact: onVerifyContact,
        onBack: onBack,
        error: error,
        notice: notice,
        showConversationListWhenEmpty: showConversationListWhenEmpty,
        canSend: canSend,
        peerTyping: peerTyping,
        peerOnline: peerOnline,
      ),
    );
  }
}
