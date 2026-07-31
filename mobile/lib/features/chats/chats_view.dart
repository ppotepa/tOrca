import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/async_operation_state.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/async/themed_activity_indicator.dart';
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
    final sendState = ref.watch(
      uiOperationProvider(UiOperationKey.messageSend(conversationId)),
    );
    final verifyState = ref.watch(
      uiOperationProvider(UiOperationKey.contactVerify(selectedContactId)),
    );

    AsyncOperationState? messageOperation;
    String messageOperationLabel = '';
    for (final message in messages) {
      final retryState = ref.watch(
        uiOperationProvider(UiOperationKey.messageRetry(message.id)),
      );
      final deleteState = ref.watch(
        uiOperationProvider(UiOperationKey.messageDelete(message.id)),
      );
      if (retryState.busy) {
        messageOperation = retryState;
        messageOperationLabel = 'Ponawianie wiadomości…';
        break;
      }
      if (deleteState.busy) {
        messageOperation = deleteState;
        messageOperationLabel = 'Usuwanie wiadomości…';
        break;
      }
    }

    final panelState = messagesState.busy
        ? messagesState
        : openState.busy
            ? openState
            : startState;

    final chat = Stack(
      children: [
        Positioned.fill(
          child: legacy.ChatsView(
            selected: selected,
            contacts: contacts,
            conversations: conversations,
            messages: messages,
            composer: composer,
            onOpenConversation: onOpenConversation,
            onSend: sendState.busy ? (_) {} : onSend,
            onTypingChanged: onTypingChanged,
            onRetryMessage: (messageId) {
              final state = ref.read(
                uiOperationProvider(UiOperationKey.messageRetry(messageId)),
              );
              if (!state.busy) onRetryMessage(messageId);
            },
            onDeleteMessage: (messageId) {
              final state = ref.read(
                uiOperationProvider(UiOperationKey.messageDelete(messageId)),
              );
              if (!state.busy) onDeleteMessage(messageId);
            },
            onVerifyContact: verifyState.busy
                ? (_) {}
                : onVerifyContact,
            onBack: onBack,
            error: error,
            notice: notice,
            showConversationListWhenEmpty: showConversationListWhenEmpty,
            canSend: canSend && !sendState.busy,
            peerTyping: peerTyping,
            peerOnline: peerOnline,
          ),
        ),
        if (verifyState.busy)
          const Positioned(
            top: 12,
            right: 16,
            child: Material(
              type: MaterialType.transparency,
              child: ThemedActivityIndicator(
                label: 'Weryfikowanie…',
                compact: true,
              ),
            ),
          ),
        if (messageOperation?.busy == true)
          Positioned(
            top: 64,
            left: 16,
            child: Material(
              elevation: 2,
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: ThemedActivityIndicator(
                  label: messageOperationLabel,
                  compact: true,
                ),
              ),
            ),
          ),
        if (sendState.busy)
          Positioned(
            right: 16,
            bottom: 14,
            child: Material(
              elevation: 2,
              color: Theme.of(context).colorScheme.surface,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: ThemedActivityIndicator(
                  label: 'Wysyłanie…',
                  compact: true,
                ),
              ),
            ),
          ),
      ],
    );

    return BusySurface(
      state: panelState,
      presentation: messages.isEmpty
          ? BusyPresentation.replace
          : BusyPresentation.overlay,
      label: startState.busy
          ? 'Uruchamianie rozmowy…'
          : 'Ładowanie rozmowy…',
      child: chat,
    );
  }
}
