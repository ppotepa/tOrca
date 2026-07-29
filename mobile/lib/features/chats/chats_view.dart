import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/conversation_display.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/feature_header.dart';

class ChatsView extends StatefulWidget {
  const ChatsView({
    super.key,
    required this.selected,
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.composer,
    required this.onOpenConversation,
    required this.onSend,
    required this.onVerifyContact,
    required this.onBack,
    required this.error,
    required this.notice,
    this.showConversationListWhenEmpty = true,
    this.canSend = false,
  });

  final ContactRecord? selected;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final TextEditingController composer;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onSend;
  final ValueChanged<String> onVerifyContact;
  final VoidCallback onBack;
  final String error;
  final String notice;
  final bool showConversationListWhenEmpty;
  final bool canSend;

  @override
  State<ChatsView> createState() => _ChatsViewState();
}

class _ChatsViewState extends State<ChatsView> {
  @override
  Widget build(BuildContext context) {
    final contact = widget.selected;
    if (contact == null) {
      return _EmptyChatPanel(
        showConversationListWhenEmpty: widget.showConversationListWhenEmpty,
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.showConversationListWhenEmpty
            ? IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: widget.onBack,
              )
            : null,
        titleSpacing: 0,
        title: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(child: Text(contact.nickname.characters.first)),
          title: Text(
            contact.nickname.isNotEmpty ? contact.nickname : 'Kontakt',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: _PresenceInfo(
            selected: contact,
            conversations: widget.conversations,
          ),
        ),
        actions: [
          if (!contact.verified)
            TextButton(
              onPressed: () => widget.onVerifyContact(contact.id),
              child: const Text('Zweryfikuj'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.notice.isNotEmpty) _InlineNotice(message: widget.notice),
          if (widget.error.isNotEmpty)
            _InlineNotice(message: widget.error, error: true),
          Expanded(
            child: widget.messages.isEmpty
                ? _EmptyConversation(contact: contact, canSend: widget.canSend)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    itemCount: widget.messages.length,
                    itemBuilder: (context, index) => _MessageTile(
                      message: widget.messages[index],
                      showDateHeader:
                          index == 0 ||
                          !_sameDay(
                            previous: widget.messages[index - 1].createdAt,
                            current: widget.messages[index].createdAt,
                          ),
                    ),
                  ),
          ),
          _Composer(
            composer: widget.composer,
            onSend: widget.onSend,
            canSend: widget.canSend,
          ),
        ],
      ),
    );
  }
}

class _EmptyChatPanel extends StatelessWidget {
  const _EmptyChatPanel({required this.showConversationListWhenEmpty});
  final bool showConversationListWhenEmpty;

  @override
  Widget build(BuildContext context) => showConversationListWhenEmpty
      ? ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            FeatureHeader(title: 'Wiadomości', subtitle: 'Wybierz rozmowę'),
            SizedBox(height: 8),
            Text(
              'Wybierz rozmowę z listy po lewej stronie.',
              style: TextStyle(fontSize: 14),
            ),
          ],
        )
      : const SizedBox.shrink();
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.contact, required this.canSend});
  final ContactRecord contact;
  final bool canSend;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            canSend
                ? 'Brak wiadomości z ${contact.nickname.isNotEmpty ? contact.nickname : 'tym kontaktem'}.'
                : 'Nie można jeszcze pisać do tego kontaktu.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final palette = context.statusTheme;
    return ColoredBox(
      color: error
          ? palette.danger.withValues(alpha: .12)
          : palette.success.withValues(alpha: .12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Text(
          message,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: error ? palette.danger : palette.success,
          ),
        ),
      ),
    );
  }
}

class _PresenceInfo extends StatelessWidget {
  const _PresenceInfo({required this.selected, required this.conversations});

  final ContactRecord selected;
  final List<ConversationSummary> conversations;

  @override
  Widget build(BuildContext context) {
    final id = selected.id;
    final presence = conversations
        .where((item) => item.contactId == id)
        .firstOrNull
        ?.state
        .presenceLabel;
    final conversationId = conversations
        .where((item) => item.contactId == id)
        .firstOrNull
        ?.id;
    final seen = conversationLastSeenLabel(conversationId, conversations);
    return Text(
      presence == null ? 'podłączony' : '$presence$seen',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: conversationPresenceColorByState(context, presence),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.composer,
    required this.onSend,
    required this.canSend,
  });

  final TextEditingController composer;
  final VoidCallback onSend;
  final bool canSend;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: composer,
                enabled: canSend,
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: canSend ? 'Napisz wiadomość…' : 'Brak uprawnień',
                  isDense: true,
                  filled: true,
                  fillColor: theme.composerBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.bubbleRadius / 2),
                    borderSide: BorderSide(
                      color: theme.composerBorder,
                      width: 1.25,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.bubbleRadius / 2),
                    borderSide: BorderSide(
                      color: theme.composerBorder,
                      width: 1.25,
                    ),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.bubbleRadius / 2),
                    borderSide: BorderSide(
                      color: theme.composerBorder.withValues(alpha: .4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canSend ? onSend : null,
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.showDateHeader});
  final ChatMessage message;
  final bool showDateHeader;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showDateHeader) ...[
        _DayDivider(date: message.createdAt),
        const SizedBox(height: 8),
      ],
      MessageBubble(message: message),
    ],
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final isOutgoing = message.outgoing;
    final isMine = isOutgoing;
    final background = isMine ? theme.outgoingBubble : theme.incomingBubble;
    final foreground = isMine
        ? theme.outgoingForeground
        : theme.incomingForeground;
    final border = BorderSide(
      color: isMine
          ? theme.outgoingBubble.withValues(alpha: 0)
          : theme.incomingBubble.withValues(alpha: 0),
      width: theme.bubbleBorderWidth,
    );

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: theme.bubblePadding,
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(theme.bubbleRadius),
            topRight: Radius.circular(theme.bubbleRadius),
            bottomLeft: Radius.circular(isMine ? theme.bubbleRadius : 0),
            bottomRight: Radius.circular(isMine ? 0 : theme.bubbleRadius),
          ),
          border: theme.bubbleBorderWidth > 0
              ? Border.all(color: border.color, width: border.width)
              : null,
          boxShadow: theme.bubbleShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.text, style: TextStyle(color: foreground)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatMessageTime(message.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: theme.metadataForeground.withValues(alpha: .95),
                  ),
                ),
                if (message.state != MessageState.delivered) ...[
                  const SizedBox(width: 8),
                  Text(
                    '• ${message.state.label}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: theme.metadataForeground.withValues(alpha: .95),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});
  final String date;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        formatMessageDay(date),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

bool _sameDay({required String previous, required String current}) =>
    isSameMessageDay(previous, current);
