import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/attachments/image_message_codec.dart';
import '../../core/models/domain.dart';
import 'chats_view.dart' show MessageBubble;

class ReleaseMessageBubble extends StatelessWidget {
  const ReleaseMessageBubble({
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
  Widget build(BuildContext context) {
    if (!isImageMessageBody(message.text)) {
      return MessageBubble(
        message: message,
        contactName: contactName,
        startsGroup: startsGroup,
        endsGroup: endsGroup,
        onRetry: onRetry,
        onDelete: onDelete,
        onReply: onReply,
      );
    }

    final decoded = decodeImageMessageBody(message.text);
    final mine = message.outgoing;
    final chat = context.chatTheme;
    final foreground = mine
        ? chat.outgoingForeground
        : chat.incomingForeground;
    final background = mine ? chat.outgoingBubble : chat.incomingBubble;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: decoded == null
            ? null
            : () => _showPreview(
                  context,
                  decoded.bytes,
                  contactName: mine ? 'Ty' : contactName,
                ),
        onLongPress: () => _showActions(context),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(chat.bubbleRadius),
            border: chat.bubbleBorderWidth > 0
                ? Border.all(
                    color: chat.composerBorder,
                    width: chat.bubbleBorderWidth,
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (startsGroup)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 6),
                  child: Text(
                    mine ? 'Ty' : contactName,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: foreground.withValues(alpha: .82),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              if (decoded == null)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ThemedIcon(
                        Icons.broken_image_outlined,
                        color: foreground,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Nie udało się odczytać obrazu.',
                          style: TextStyle(color: foreground),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Hero(
                  tag: 'image-message-${message.id}',
                  child: Image.memory(
                    decoded.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, _, _) => Container(
                      height: 180,
                      alignment: Alignment.center,
                      child: ThemedIcon(
                        Icons.broken_image_outlined,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 10, 7),
                color: foreground.withValues(alpha: .075),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      decoded == null
                          ? 'obraz uszkodzony'
                          : '${decoded.width}×${decoded.height} · '
                              '${decoded.bytes.lengthInBytes ~/ 1024} KiB',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: .72),
                          ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _stateIcon(message.state),
                      size: 14,
                      color: message.state == MessageState.failed
                          ? context.statusTheme.danger
                          : foreground.withValues(alpha: .72),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPreview(
    BuildContext context,
    Uint8List bytes, {
    required String contactName,
  }) => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(contactName)),
            backgroundColor: Colors.black,
            body: InteractiveViewer(
              minScale: .5,
              maxScale: 5,
              child: Center(
                child: Hero(
                  tag: 'image-message-${message.id}',
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            if (message.outgoing && message.state == MessageState.failed)
              ListTile(
                leading: const ThemedIcon(Icons.refresh),
                title: const Text('Spróbuj ponownie'),
                onTap: () => Navigator.pop(sheetContext, 'retry'),
              ),
            ListTile(
              leading: const ThemedIcon(Icons.delete_outline),
              title: const Text('Usuń tylko na tym urządzeniu'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'retry') onRetry(message.id);
    if (action == 'delete') onDelete(message.id);
  }
}

IconData _stateIcon(MessageState state) => switch (state) {
      MessageState.queued => Icons.hourglass_bottom,
      MessageState.sending => Icons.schedule,
      MessageState.sent => Icons.done,
      MessageState.delivered || MessageState.read => Icons.done_all,
      MessageState.failed => Icons.error_outline,
    };
