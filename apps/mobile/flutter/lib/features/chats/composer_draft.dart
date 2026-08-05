import 'dart:typed_data';

import '../../core/attachments/image_attachment_policy.dart';
import '../../core/attachments/image_message_codec.dart';

const maxComposerAttachments =
    ImageAttachmentPolicy.maximumAttachmentsPerMessage;

class ComposerAttachment {
  const ComposerAttachment({
    required this.attachment,
    required this.previewBytes,
  });

  final PreparedImageAttachment attachment;
  final Uint8List previewBytes;
}

class ComposerDraft {
  const ComposerDraft({
    this.caption = '',
    this.attachments = const [],
    this.replyToMessageId,
  });

  final String caption;
  final List<ComposerAttachment> attachments;
  final String? replyToMessageId;

  bool get isEmpty => caption.trim().isEmpty && attachments.isEmpty;
}
