import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/themed_activity_indicator.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/message_delivery_surface.dart';

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.contactName = '',
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
    final retry = ref.watch(
      uiOperationProvider(UiOperationKey.messageRetry(message.id)),
    );
    final deletion = ref.watch(
      uiOperationProvider(UiOperationKey.messageDelete(message.id)),
    );
    final busy = retry.busy || deletion.busy;
    final theme = context.chatTheme;
    final mine = message.outgoing;
    final foreground = mine
        ? theme.outgoingForeground
        : theme.incomingForeground;
    final radius = theme.bubbleRadius;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: busy
            ? null
            : (event) => _showMenu(context, event.globalPosition),
        onSecondaryTapDown: busy
            ? null
            : (event) => _showMenu(context, event.globalPosition),
        child: MessageDeliverySurface(
          state: message.state,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: busy ? .58 : 1,
            child: IntrinsicWidth(
              child: Container(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 560),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: mine ? theme.outgoingBubble : theme.incomingBubble,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(startsGroup ? radius : radius / 3),
                    topRight: Radius.circular(
                      startsGroup ? radius : radius / 3,
                    ),
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
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(color: foreground),
                          ),
                        ],
                      ),
                    ),
                    _BubbleFooter(
                      message: message,
                      foreground: foreground,
                      busyLabel: retry.busy
                          ? 'Ponawianie…'
                          : deletion.busy
                          ? 'Usuwanie…'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
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
    switch (action) {
      case 'reply':
        onReply(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
      case 'retry':
        onRetry(message.id);
      case 'delete':
        onDelete(message.id);
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
      MessageState.delivered || MessageState.read => Icons.done_all,
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
              label: busyLabel!,
              compact: true,
              color: foreground.withValues(alpha: .82),
            ),
            const SizedBox(width: 12),
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
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: foreground.withValues(alpha: .84)),
    ),
  );
}
