import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/async_operation_state.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/async/themed_activity_indicator.dart';
import '../../shared/formatters/conversation_display.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_avatar.dart';

export 'chats_view_legacy.dart' hide ChatsView, MessageBubble;

class ChatsView extends ConsumerStatefulWidget {
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
  ConsumerState<ChatsView> createState() => _ChatsViewState();
}

class _ChatsViewState extends ConsumerState<ChatsView> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _typingTimer;
  ChatMessage? _replyingTo;
  bool _searching = false;

  @override
  void didUpdateWidget(covariant ChatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length > oldWidget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    widget.onTypingChanged(false);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _conversationId {
    final contactId = widget.selected?.id ?? '';
    for (final conversation in widget.conversations) {
      if (conversation.contactId == contactId) return conversation.id;
    }
    return contactId;
  }

  List<ChatMessage> get _visibleMessages {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.messages;
    return widget.messages
        .where((message) => message.text.toLowerCase().contains(query))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final contact = widget.selected;
    if (contact == null) {
      return _ConversationHome(
        conversations: widget.conversations,
        contacts: widget.contacts,
        onOpenConversation: widget.onOpenConversation,
        compact: widget.showConversationListWhenEmpty,
      );
    }

    final conversationId = _conversationId;
    final openState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationOpen(conversationId)),
    );
    final startState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationStart(contact.id)),
    );
    final messagesState = ref.watch(
      uiOperationProvider(UiOperationKey.messagesLoad(conversationId)),
    );
    final sendState = ref.watch(
      uiOperationProvider(UiOperationKey.messageSend(conversationId)),
    );
    final verifyState = ref.watch(
      uiOperationProvider(UiOperationKey.contactVerify(contact.id)),
    );
    final panelState = messagesState.busy
        ? messagesState
        : openState.busy
            ? openState
            : startState;

    return BusySurface(
      state: panelState,
      presentation: widget.messages.isEmpty
          ? BusyPresentation.replace
          : BusyPresentation.overlay,
      label: startState.busy
          ? 'Uruchamianie rozmowy…'
          : 'Ładowanie rozmowy…',
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _ConversationHeader(
          contact: contact,
          conversations: widget.conversations,
          searching: _searching,
          searchController: _search,
          peerTyping: widget.peerTyping,
          peerOnline: widget.peerOnline,
          verifyBusy: verifyState.busy,
          showBack: widget.showConversationListWhenEmpty,
          onBack: widget.onBack,
          onSearchToggle: () => setState(() {
            _searching = !_searching;
            if (!_searching) _search.clear();
          }),
          onSearchChanged: (_) => setState(() {}),
          onVerify: contact.verified || verifyState.busy
              ? null
              : () => widget.onVerifyContact(contact.id),
        ),
        body: Column(
          children: [
            if (widget.notice.trim().isNotEmpty)
              _InlineStatus(message: widget.notice),
            if (widget.error.trim().isNotEmpty)
              _InlineStatus(message: widget.error, error: true),
            Expanded(
              child: _MessageTimeline(
                controller: _scroll,
                messages: _visibleMessages,
                contact: contact,
                canSend: widget.canSend,
                searchActive: _searching && _search.text.trim().isNotEmpty,
                onRetry: widget.onRetryMessage,
                onDelete: widget.onDeleteMessage,
                onReply: (message) => setState(() => _replyingTo = message),
              ),
            ),
            _ComposerDock(
              composer: widget.composer,
              replyTo: _replyingTo,
              canSend: widget.canSend && !sendState.busy,
              sending: sendState.busy,
              onCancelReply: () => setState(() => _replyingTo = null),
              onTypingChanged: _typingChanged,
              onSend: () {
                final replyId = _replyingTo?.id;
                setState(() => _replyingTo = null);
                widget.onSend(replyId);
              },
            ),
          ],
        ),
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
}

class _ConversationHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const _ConversationHeader({
    required this.contact,
    required this.conversations,
    required this.searching,
    required this.searchController,
    required this.peerTyping,
    required this.peerOnline,
    required this.verifyBusy,
    required this.showBack,
    required this.onBack,
    required this.onSearchToggle,
    required this.onSearchChanged,
    required this.onVerify,
  });

  final ContactRecord contact;
  final List<ConversationSummary> conversations;
  final bool searching;
  final TextEditingController searchController;
  final bool peerTyping;
  final bool peerOnline;
  final bool verifyBusy;
  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onSearchToggle;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback? onVerify;

  @override
  Size get preferredSize => const Size.fromHeight(68);

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    var conversationState = ConversationState.pending;
    for (final conversation in conversations) {
      if (conversation.contactId == contact.id) {
        conversationState = conversation.state;
        break;
      }
    }
    final route = contact.peerConnectionStatus == PeerConnectionStatus.connected
        ? 'bezpośrednio przez Tor P2P'
        : 'przez Tor relay';
    final presence = peerTyping
        ? 'pisze…'
        : peerOnline
            ? 'online · $route'
            : '${conversationState.presenceLabel} · $route';

    return AppBar(
      toolbarHeight: 68,
      leading: showBack
          ? IconButton(
              tooltip: 'Wróć',
              onPressed: onBack,
              icon: const ThemedIcon(Icons.chevron_left),
            )
          : null,
      titleSpacing: showBack ? 0 : 16,
      title: searching
          ? TextField(
              controller: searchController,
              autofocus: true,
              onChanged: onSearchChanged,
              decoration: const InputDecoration(
                hintText: 'Szukaj lokalnie w rozmowie…',
                border: InputBorder.none,
              ),
            )
          : Row(
              children: [
                IdentityAvatar(label: contact.displayName),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              contact.displayName.isEmpty
                                  ? 'Kontakt'
                                  : contact.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          if (contact.verified) ...[
                            const SizedBox(width: 6),
                            ThemedIcon(
                              Icons.verified_user_outlined,
                              size: 15,
                              color: context.statusTheme.success,
                            ),
                          ],
                        ],
                      ),
                      Text(
                        presence,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: peerTyping || peerOnline
                                  ? context.statusTheme.success
                                  : shell.navigationForeground,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      actions: [
        if (verifyBusy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: ThemedActivityIndicator(compact: true),
          )
        else if (onVerify != null)
          TextButton.icon(
            onPressed: onVerify,
            icon: const ThemedIcon(Icons.verified_user_outlined, size: 16),
            label: const Text('Zweryfikuj'),
          ),
        IconButton(
          tooltip: searching ? 'Zamknij wyszukiwanie' : 'Szukaj',
          onPressed: onSearchToggle,
          icon: ThemedIcon(searching ? Icons.close : Icons.search),
        ),
        PopupMenuButton<String>(
          tooltip: 'Opcje rozmowy',
          icon: const ThemedIcon(Icons.more_vert),
          onSelected: (value) async {
            if (value == 'fingerprint') {
              await Clipboard.setData(
                ClipboardData(text: contact.fingerprint),
              );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'fingerprint',
              child: Text('Kopiuj fingerprint'),
            ),
          ],
        ),
      ],
    );
  }
}

class _MessageTimeline extends StatelessWidget {
  const _MessageTimeline({
    required this.controller,
    required this.messages,
    required this.contact,
    required this.canSend,
    required this.searchActive,
    required this.onRetry,
    required this.onDelete,
    required this.onReply,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final ContactRecord contact;
  final bool canSend;
  final bool searchActive;
  final ValueChanged<String> onRetry;
  final ValueChanged<String> onDelete;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                searchActive ? Icons.search_off : Icons.forum_outlined,
                size: 42,
                color: context.shellTheme.navigationForeground,
              ),
              const SizedBox(height: 12),
              Text(
                searchActive
                    ? 'Brak wiadomości pasujących do wyszukiwania.'
                    : canSend
                        ? 'To początek rozmowy z ${contact.displayName}.'
                        : 'Rozmowa oczekuje na bezpieczny handshake MLS.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: ListView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            final previous = index == 0 ? null : messages[index - 1];
            final next = index + 1 >= messages.length
                ? null
                : messages[index + 1];
            final showDay = previous == null ||
                !isSameMessageDay(
                  previous.createdAt,
                  message.createdAt,
                );
            final startsGroup = previous == null ||
                previous.outgoing != message.outgoing ||
                showDay;
            final endsGroup = next == null ||
                next.outgoing != message.outgoing ||
                !isSameMessageDay(message.createdAt, next.createdAt);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDay) _DayDivider(date: message.createdAt),
                MessageBubble(
                  message: message,
                  contactName: contact.displayName,
                  startsGroup: startsGroup,
                  endsGroup: endsGroup,
                  onRetry: onRetry,
                  onDelete: onDelete,
                  onReply: onReply,
                ),
                SizedBox(height: endsGroup ? 10 : 3),
              ],
            );
          },
        ),
      ),
    );
  }
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.contactName,
    required this.startsGroup,
    required this.endsGroup,
    required this.onRetry,
    required this.onDelete,
    required this.onReply,
  });

  final ChatMessage message;
  final String contactName;
  final bool startsGroup;
  final bool endsGroup;
  final ValueChanged<String> onRetry;
  final ValueChanged<String> onDelete;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retryState = ref.watch(
      uiOperationProvider(UiOperationKey.messageRetry(message.id)),
    );
    final deleteState = ref.watch(
      uiOperationProvider(UiOperationKey.messageDelete(message.id)),
    );
    final busy = retryState.busy || deleteState.busy;
    final theme = context.chatTheme;
    final mine = message.outgoing;
    final background = mine ? theme.outgoingBubble : theme.incomingBubble;
    final foreground = mine
        ? theme.outgoingForeground
        : theme.incomingForeground;
    final radius = theme.bubbleRadius;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: busy
            ? null
            : (details) => _showMenu(context, details.globalPosition),
        onSecondaryTapDown: busy
            ? null
            : (details) => _showMenu(context, details.globalPosition),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: busy ? .58 : 1,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 720),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(startsGroup ? radius : radius / 3),
                topRight: Radius.circular(startsGroup ? radius : radius / 3),
                bottomLeft: Radius.circular(
                  mine || !endsGroup ? radius : radius / 4,
                ),
                bottomRight: Radius.circular(
                  mine && endsGroup ? radius / 4 : radius,
                ),
              ),
              border: theme.bubbleBorderWidth > 0
                  ? Border.all(
                      color: theme.composerBorder,
                      width: theme.bubbleBorderWidth,
                    )
                  : null,
              boxShadow: theme.bubbleShadow,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (startsGroup)
                  _BubbleHeader(
                    label: mine ? 'Ty' : contactName,
                    foreground: foreground,
                  ),
                Padding(
                  padding: theme.bubblePadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.replyTo != null) ...[
                        _QuotedMessage(
                          reply: message.replyTo!,
                          foreground: foreground,
                        ),
                        const SizedBox(height: 7),
                      ],
                      SelectableText(
                        message.text,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: foreground,
                            ),
                      ),
                    ],
                  ),
                ),
                _BubbleFooter(
                  message: message,
                  foreground: foreground,
                  busyLabel: retryState.busy
                      ? 'Ponawianie…'
                      : deleteState.busy
                          ? 'Usuwanie…'
                          : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
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
    switch (action) {
      case 'reply':
        onReply(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
      case 'retry':
        onRetry(message.id);
      case 'delete':
        onDelete(message.id);
      default:
        break;
    }
  }
}

class _BubbleHeader extends StatelessWidget {
  const _BubbleHeader({required this.label, required this.foreground});

  final String label;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 6),
        color: foreground.withValues(alpha: .055),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground.withValues(alpha: .82),
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}

class _BubbleFooter extends StatelessWidget {
  const _BubbleFooter({
    required this.message,
    required this.foreground,
    this.busyLabel,
  });

  final ChatMessage message;
  final Color foreground;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    final icon = switch (message.state) {
      MessageState.queued => Icons.hourglass_bottom,
      MessageState.sending => Icons.schedule,
      MessageState.sent => Icons.done,
      MessageState.delivered => Icons.done_all,
      MessageState.read => Icons.done_all,
      MessageState.failed => Icons.error_outline,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 10, 7),
      color: foreground.withValues(alpha: .075),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (busyLabel != null) ...[
            ThemedActivityIndicator(
              label: busyLabel,
              compact: true,
              color: foreground.withValues(alpha: .82),
            ),
            const Spacer(),
          ],
          Text(
            formatMessageTime(message.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: .72),
                ),
          ),
          const SizedBox(width: 7),
          Icon(icon, size: 14, color: foreground.withValues(alpha: .72)),
          const SizedBox(width: 4),
          Text(
            message.state.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: message.state == MessageState.failed
                      ? context.statusTheme.danger
                      : foreground.withValues(alpha: .72),
                ),
          ),
        ],
      ),
    );
  }
}

class _ComposerDock extends StatelessWidget {
  const _ComposerDock({
    required this.composer,
    required this.replyTo,
    required this.canSend,
    required this.sending,
    required this.onCancelReply,
    required this.onTypingChanged,
    required this.onSend,
  });

  final TextEditingController composer;
  final ChatMessage? replyTo;
  final bool canSend;
  final bool sending;
  final VoidCallback onCancelReply;
  final ValueChanged<String> onTypingChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final chat = context.chatTheme;
    return Material(
      color: shell.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: shell.border, width: shell.borderWidth),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
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
                  },
                  child: TextField(
                    controller: composer,
                    enabled: canSend,
                    minLines: 1,
                    maxLines: 5,
                    onChanged: onTypingChanged,
                    onSubmitted: (_) {
                      if (canSend && composer.text.trim().isNotEmpty) onSend();
                    },
                    decoration: InputDecoration(
                      hintText: canSend
                          ? 'Napisz wiadomość…'
                          : 'Rozmowa nie jest jeszcze gotowa',
                      filled: true,
                      fillColor: chat.composerBackground,
                      prefixIcon: const ThemedIcon(Icons.lock_outline, size: 18),
                      suffixIconConstraints: const BoxConstraints.tightFor(
                        width: 58,
                        height: 52,
                      ),
                      suffixIcon: FilledButton(
                        onPressed: canSend && composer.text.trim().isNotEmpty
                            ? onSend
                            : null,
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: context.effectsTheme.pixelated
                                ? BorderRadius.zero
                                : BorderRadius.circular(chat.bubbleRadius / 2),
                          ),
                        ),
                        child: sending
                            ? const ThemedActivityIndicator(compact: true)
                            : const ThemedIcon(Icons.send, size: 19),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.message, required this.onClose});

  final ChatMessage message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.outgoing ? 'Odpowiedź na Twoją wiadomość' : 'Odpowiedź',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    message.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Anuluj odpowiedź',
              onPressed: onClose,
              icon: const ThemedIcon(Icons.close, size: 18),
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
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: .08),
          border: Border(left: BorderSide(color: foreground, width: 3)),
        ),
        child: Text(
          reply.text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: foreground.withValues(alpha: .84),
              ),
        ),
      );
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final String date;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: context.shellTheme.surface,
            border: Border.all(color: context.shellTheme.border),
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

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 140),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: error
              ? context.statusTheme.danger.withValues(alpha: .12)
              : context.statusTheme.success.withValues(alpha: .1),
          child: Text(
            message,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: error
                      ? context.statusTheme.danger
                      : context.statusTheme.success,
                ),
          ),
        ),
      );
}

class _ConversationHome extends StatelessWidget {
  const _ConversationHome({
    required this.conversations,
    required this.contacts,
    required this.onOpenConversation,
    required this.compact,
  });

  final List<ConversationSummary> conversations;
  final List<ContactRecord> contacts;
  final ValueChanged<String> onOpenConversation;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final recent = conversations.take(4).toList(growable: false);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                Icons.shield_outlined,
                size: 54,
                color: context.statusTheme.success,
              ),
              const SizedBox(height: 14),
              Text(
                'Prywatna komunikacja przez Tor',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '${contacts.length} kontaktów · ${conversations.length} rozmów',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!compact && recent.isNotEmpty) ...[
                const SizedBox(height: 26),
                const FeatureHeader(
                  title: 'Ostatnie rozmowy',
                  subtitle: 'Wybierz rozmowę z listy lub poniżej',
                ),
                const SizedBox(height: 10),
                for (final conversation in recent)
                  ListTile(
                    leading: const ThemedIcon(Icons.chat_bubble_outline),
                    title: Text(_contactName(conversation.contactId, contacts)),
                    subtitle: Text(
                      conversation.preview.isEmpty
                          ? 'Oczekiwanie na wiadomość'
                          : conversation.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const ThemedIcon(Icons.chevron_right),
                    onTap: () => onOpenConversation(conversation.id),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _contactName(String contactId, List<ContactRecord> contacts) {
  for (final contact in contacts) {
    if (contact.id == contactId) return contact.displayName;
  }
  return 'Kontakt';
}
