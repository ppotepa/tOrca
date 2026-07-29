import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/conversation_display.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_avatar.dart';

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
  State<ChatsView> createState() => _ChatsViewState();
}

class _ChatsViewState extends State<ChatsView> {
  final _search = TextEditingController();
  bool _searching = false;
  ChatMessage? _replyingTo;
  Timer? _typingTimer;

  @override
  void dispose() {
    _typingTimer?.cancel();
    widget.onTypingChanged(false);
    _search.dispose();
    super.dispose();
  }

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
                icon: const ThemedIcon(Icons.chevron_left),
                onPressed: widget.onBack,
              )
            : null,
        titleSpacing: 0,
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Szukaj lokalnie w rozmowie',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: IdentityAvatar(label: contact.displayName),
                title: Text(
                  contact.displayName.isNotEmpty
                      ? contact.displayName
                      : 'Kontakt',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                subtitle: _PresenceInfo(
                  selected: contact,
                  conversations: widget.conversations,
                  typing: widget.peerTyping,
                  online: widget.peerOnline,
                ),
              ),
        actions: [
          IconButton(
            tooltip: _searching ? 'Zamknij wyszukiwanie' : 'Szukaj',
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              });
            },
            icon: ThemedIcon(_searching ? Icons.close : Icons.search),
          ),
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
            child: _visibleMessages.isEmpty
                ? _EmptyConversation(contact: contact, canSend: widget.canSend)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    itemCount: _visibleMessages.length,
                    itemBuilder: (context, index) => _MessageTile(
                      message: _visibleMessages[index],
                      onRetry: widget.onRetryMessage,
                      onDelete: widget.onDeleteMessage,
                      onReply: (message) =>
                          setState(() => _replyingTo = message),
                      showDateHeader:
                          index == 0 ||
                          !_sameDay(
                            previous: _visibleMessages[index - 1].createdAt,
                            current: _visibleMessages[index].createdAt,
                          ),
                    ),
                  ),
          ),
          _Composer(
            composer: widget.composer,
            onSend: () {
              final replyId = _replyingTo?.id;
              setState(() => _replyingTo = null);
              widget.onSend(replyId);
            },
            canSend: widget.canSend,
            replyTo: _replyingTo,
            onCancelReply: () => setState(() => _replyingTo = null),
            onTypingChanged: _typingChanged,
          ),
        ],
      ),
    );
  }

  void _typingChanged(String value) {
    _typingTimer?.cancel();
    final typing = value.trim().isNotEmpty;
    widget.onTypingChanged(typing);
    if (typing) {
      _typingTimer = Timer(
        const Duration(seconds: 2),
        () => widget.onTypingChanged(false),
      );
    }
  }

  List<ChatMessage> get _visibleMessages {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.messages;
    return widget.messages
        .where((message) => message.text.toLowerCase().contains(query))
        .toList();
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
                ? 'Brak wiadomości z ${contact.displayName.isNotEmpty ? contact.displayName : 'tym kontaktem'}.'
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
  const _PresenceInfo({
    required this.selected,
    required this.conversations,
    required this.typing,
    required this.online,
  });

  final ContactRecord selected;
  final List<ConversationSummary> conversations;
  final bool typing;
  final bool online;

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
    final label = typing
        ? 'pisze…'
        : online
        ? 'online'
        : presence == null
        ? 'offline'
        : '$presence$seen';
    return Text(
      label,
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
    required this.replyTo,
    required this.onCancelReply,
    required this.onTypingChanged,
  });

  final TextEditingController composer;
  final VoidCallback onSend;
  final bool canSend;
  final ChatMessage? replyTo;
  final VoidCallback onCancelReply;
  final ValueChanged<String> onTypingChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final pixelated = context.effectsTheme.pixelated;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTo != null)
              _ReplyPreview(message: replyTo!, onClose: onCancelReply),
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (canSend && composer.text.trim().isNotEmpty) onSend();
                },
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  shift: true,
                ): () =>
                    _insertNewline(composer),
              },
              child: TextField(
                controller: composer,
                enabled: canSend,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (canSend && composer.text.trim().isNotEmpty) onSend();
                },
                onChanged: onTypingChanged,
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
                  suffixIconConstraints: const BoxConstraints.tightFor(
                    width: 56,
                    height: 56,
                  ),
                  suffixIcon: FilledButton(
                    onPressed: canSend ? onSend : null,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: pixelated
                            ? BorderRadius.zero
                            : BorderRadius.circular(theme.bubbleRadius / 2),
                      ),
                    ),
                    child: const ThemedIcon(Icons.send),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _insertNewline(TextEditingController controller) {
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;
    controller.value = controller.value.copyWith(
      text: controller.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.message,
    required this.showDateHeader,
    required this.onRetry,
    required this.onDelete,
    required this.onReply,
  });
  final ChatMessage message;
  final bool showDateHeader;
  final ValueChanged<String> onRetry, onDelete;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showDateHeader) ...[
        _DayDivider(date: message.createdAt),
        const SizedBox(height: 8),
      ],
      MessageBubble(
        message: message,
        onRetry: onRetry,
        onDelete: onDelete,
        onReply: onReply,
      ),
    ],
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onDelete,
    required this.onReply,
  });

  final ChatMessage message;
  final ValueChanged<String> onRetry, onDelete;
  final ValueChanged<ChatMessage> onReply;

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
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showMessageMenu(context, details.globalPosition),
        onSecondaryTapDown: (details) =>
            _showMessageMenu(context, details.globalPosition),
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
              if (message.replyTo != null) ...[
                _QuotedMessage(reply: message.replyTo!, foreground: foreground),
                const SizedBox(height: 6),
              ],
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
      ),
    );
  }

  Future<void> _showMessageMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'reply', child: Text('Odpowiedz')),
        const PopupMenuItem(value: 'copy', child: Text('Kopiuj wiadomość')),
        if (message.outgoing && message.state == MessageState.failed)
          const PopupMenuItem(value: 'retry', child: Text('Spróbuj ponownie')),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Usuń tylko na tym urządzeniu'),
        ),
      ],
    );
    if (action == 'reply') {
      onReply(message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.text));
    } else if (action == 'retry') {
      onRetry(message.id);
    } else if (action == 'delete') {
      onDelete(message.id);
    }
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.message, required this.onClose});
  final ChatMessage message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      border: Border(
        left: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 3,
        ),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Odpowiedź na: ${message.text}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Anuluj odpowiedź',
          onPressed: onClose,
          icon: const ThemedIcon(Icons.close),
        ),
      ],
    ),
  );
}

class _QuotedMessage extends StatelessWidget {
  const _QuotedMessage({required this.reply, required this.foreground});
  final MessageReply reply;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: foreground.withValues(alpha: .08),
      border: Border(left: BorderSide(color: foreground, width: 3)),
    ),
    child: Text(
      reply.text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: foreground),
    ),
  );
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
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(999),
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
