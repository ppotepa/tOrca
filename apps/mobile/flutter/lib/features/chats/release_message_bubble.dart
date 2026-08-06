import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../core/attachments/encrypted_image_store.dart';
import '../../core/attachments/image_gallery_service.dart';
import '../../core/attachments/image_message_codec.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../core/relationships/relationship_message.dart';
import '../../shared/widgets/message_delivery_surface.dart';
import '../../locales/presentation/app_localizations_x.dart';
import 'message_bubble.dart';

class ReleaseMessageBubble extends ConsumerStatefulWidget {
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
  ConsumerState<ReleaseMessageBubble> createState() =>
      _ReleaseMessageBubbleState();
}

class _ReleaseMessageBubbleState extends ConsumerState<ReleaseMessageBubble> {
  Uint8List? _imageBytes;
  bool _loading = false;
  bool _saving = false;
  bool _cached = false;

  ChatMessage get message => widget.message;

  @override
  void initState() {
    super.initState();
    unawaited(_loadImage());
  }

  @override
  void didUpdateWidget(covariant ReleaseMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.text != widget.message.text) {
      _imageBytes = null;
      _cached = false;
      unawaited(_loadImage());
    }
  }

  Future<void> _loadImage({bool force = false}) async {
    final messageId = message.id;
    final messageText = message.text;
    final outgoing = message.outgoing;
    final decoded = decodeImageMessageBody(messageText);
    if (decoded == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final store = EncryptedImageStore.instance;
      var bytes = await store.read(messageId);
      var cached = bytes != null;
      final automatic =
          await ImageAttachmentPreferences.automaticDownloadEnabled();
      if (bytes == null && (force || outgoing || automatic)) {
        await store.put(messageId, decoded.bytes);
        bytes = decoded.bytes;
        cached = true;
      }
      if (!mounted ||
          widget.message.id != messageId ||
          widget.message.text != messageText) {
        return;
      }
      setState(() {
        _imageBytes = bytes;
        _cached = cached;
      });
    } finally {
      if (mounted && widget.message.id == messageId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _removeFromCache() async {
    await EncryptedImageStore.instance.remove(message.id);
    if (!mounted) return;
    setState(() {
      _imageBytes = null;
      _cached = false;
    });
  }

  Future<void> _saveToGallery() async {
    final bytes = _imageBytes;
    if (bytes == null || _saving) return;
    setState(() => _saving = true);
    try {
      await ImageGalleryService.saveJpeg(bytes, messageId: message.id);
      if (mounted) {
        ref
            .read(uiNotificationCenterProvider.notifier)
            .showSuccess(
              context.l10n.uiImageSavedToGallery,
              deduplicationKey: 'image-saved:${message.id}',
            );
      }
    } catch (error) {
      if (mounted) {
        ref
            .read(uiNotificationCenterProvider.notifier)
            .showError(
              context.l10n.uiImageSaveFailed,
              deduplicationKey:
                  'image-save-error:${message.id}:${error.runtimeType}',
            );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final removed = RelationshipRemovedMessage.tryDecode(message.text);
    if (removed != null) {
      return _RelationshipRemovedEvent(
        message: message,
        contactName: widget.contactName,
        removed: removed,
      );
    }
    if (!isImageMessageBody(message.text)) {
      return MessageBubble(
        message: message,
        contactName: widget.contactName,
        startsGroup: widget.startsGroup,
        endsGroup: widget.endsGroup,
        onRetry: widget.onRetry,
        onDelete: widget.onDelete,
        onReply: widget.onReply,
      );
    }

    final decoded = decodeImageMessageBody(message.text);
    final mine = message.outgoing;
    final chat = context.chatTheme;
    final foreground = mine ? chat.outgoingForeground : chat.incomingForeground;
    final background = mine ? chat.outgoingBubble : chat.incomingBubble;
    final imageLabel = mine
        ? context.l10n.uiSentImage
        : context.l10n.uiImageFrom(widget.contactName);

    return Semantics(
      container: true,
      button: decoded != null && _imageBytes != null,
      label: imageLabel,
      hint: _imageBytes == null
          ? context.l10n.uiDownloadEncryptedImage
          : context.l10n.uiOpenImagePreview,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onTap: _imageBytes == null
              ? null
              : () => _showPreview(
                  context,
                  _imageBytes!,
                  contactName: mine ? context.l10n.uiYou : widget.contactName,
                ),
          onLongPress: () => _showActions(context),
          child: MessageDeliverySurface(
            state: message.state,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 240),
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
                  if (widget.startsGroup)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 7, 12, 6),
                      child: Text(
                        mine ? context.l10n.uiYou : widget.contactName,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: foreground.withValues(alpha: .82),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  _imageContent(context, decoded, foreground),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 10, 7),
                    color: foreground.withValues(alpha: .075),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(
                          _cached
                              ? Icons.lock_outline
                              : Icons.cloud_download_outlined,
                          size: 13,
                          color: foreground.withValues(alpha: .72),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            decoded == null
                                ? context.l10n.uiCorruptedImage
                                : '${decoded.width}×${decoded.height} · '
                                      '${decoded.bytes.lengthInBytes ~/ 1024} KiB',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: foreground.withValues(alpha: .72),
                                ),
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
                        const SizedBox(width: 4),
                        Text(
                          _stateLabel(context, message.state),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: message.state == MessageState.failed
                                    ? context.statusTheme.danger
                                    : foreground.withValues(alpha: .72),
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _imageContent(
    BuildContext context,
    DecodedImageMessage? decoded,
    Color foreground,
  ) {
    if (decoded == null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemedIcon(Icons.broken_image_outlined, color: foreground),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                context.l10n.uiImageReadFailed,
                style: TextStyle(color: foreground),
              ),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return SizedBox(
        width: 200,
        height: 200,
        child: Center(child: CircularProgressIndicator(color: foreground)),
      );
    }
    if (_imageBytes == null) {
      return SizedBox(
        width: 200,
        height: 200,
        child: Center(
          child: FilledButton.tonalIcon(
            onPressed: () => _loadImage(force: true),
            icon: const ThemedIcon(Icons.download_outlined),
            label: Text(context.l10n.imageDownload),
          ),
        ),
      );
    }
    return Hero(
      tag: 'image-message-${message.id}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
        child: Image.memory(
          _imageBytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => Container(
            width: 200,
            height: 200,
            alignment: Alignment.center,
            child: ThemedIcon(Icons.broken_image_outlined, color: foreground),
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
        appBar: AppBar(
          title: Text(contactName),
          actions: [
            IconButton(
              tooltip: context.l10n.imageSaveToGallery,
              onPressed: _saveToGallery,
              icon: const ThemedIcon(Icons.download_for_offline_outlined),
            ),
          ],
        ),
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
            if (_imageBytes == null &&
                decodeImageMessageBody(message.text) != null)
              ListTile(
                leading: const ThemedIcon(Icons.download_outlined),
                title: Text(context.l10n.imageDownload),
                onTap: () => Navigator.pop(sheetContext, 'download'),
              ),
            if (_imageBytes != null)
              ListTile(
                leading: const ThemedIcon(Icons.download_for_offline_outlined),
                title: Text(context.l10n.imageSaveToGallery),
                onTap: () => Navigator.pop(sheetContext, 'save'),
              ),
            if (_cached)
              ListTile(
                leading: const ThemedIcon(Icons.delete_sweep_outlined),
                title: Text(context.l10n.imageRemoveFromCache),
                onTap: () => Navigator.pop(sheetContext, 'uncache'),
              ),
            if (message.outgoing && message.state == MessageState.failed)
              ListTile(
                leading: const ThemedIcon(Icons.refresh),
                title: Text(context.l10n.commonRetry),
                onTap: () => Navigator.pop(sheetContext, 'retry'),
              ),
            ListTile(
              leading: const ThemedIcon(Icons.delete_outline),
              title: Text(context.l10n.commonDeleteLocal),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'download':
        await _loadImage(force: true);
        break;
      case 'save':
        await _saveToGallery();
        break;
      case 'uncache':
        await _removeFromCache();
        break;
      case 'retry':
        widget.onRetry(message.id);
        break;
      case 'delete':
        await EncryptedImageStore.instance.remove(message.id);
        widget.onDelete(message.id);
        break;
      case null:
        break;
    }
  }
}

class _RelationshipRemovedEvent extends StatelessWidget {
  const _RelationshipRemovedEvent({
    required this.message,
    required this.contactName,
    required this.removed,
  });

  final ChatMessage message;
  final String contactName;
  final RelationshipRemovedMessage removed;

  @override
  Widget build(BuildContext context) {
    final label = message.outgoing
        ? context.l10n.uiRelationshipEndedByYou(contactName)
        : context.l10n.uiRelationshipEndedByContact(contactName);
    return Semantics(
      container: true,
      label: label,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: context.statusTheme.warning.withValues(alpha: .10),
            border: Border.all(
              color: context.statusTheme.warning.withValues(alpha: .55),
            ),
            borderRadius: context.effectsTheme.pixelated
                ? BorderRadius.zero
                : BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                Icons.person_remove_outlined,
                size: 18,
                color: context.statusTheme.warning,
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _stateIcon(MessageState state) => switch (state) {
  MessageState.queued => Icons.hourglass_bottom,
  MessageState.sending => Icons.schedule,
  MessageState.sent => Icons.done,
  MessageState.delivered || MessageState.read => Icons.done_all,
  MessageState.failed => Icons.error_outline,
};

String _stateLabel(BuildContext context, MessageState state) => switch (state) {
  _ => context.l10n.uiMessageState(state),
};
