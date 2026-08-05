import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'image_attachment_policy.dart';
import 'image_message_codec.dart';

Future<List<PreparedImageAttachment>?> pickPreparedImageAttachments() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    allowMultiple: true,
    withData: false,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return null;
  if (result.files.length > ImageAttachmentPolicy.maximumAttachmentsPerMessage) {
    throw StateError(
      'At most ${ImageAttachmentPolicy.maximumAttachmentsPerMessage} images can be selected at once.',
    );
  }

  final prepared = <PreparedImageAttachment>[];
  for (final file in result.files) {
    ImageAttachmentPolicy.validateSourceLength(file.size);
    final source = await _readBytes(file);
    ImageAttachmentPolicy.validateSourceLength(source.lengthInBytes);
    prepared.add(await prepareImageAttachment(source));
  }
  return prepared;
}

Future<PreparedImageAttachment?> pickPreparedImageAttachment() async {
  final attachments = await pickPreparedImageAttachments();
  if (attachments == null || attachments.isEmpty) return null;
  return attachments.first;
}

Future<Uint8List> _readBytes(PlatformFile file) async {
  final memory = file.bytes;
  if (memory != null) return memory;
  final path = file.path;
  if (path == null || path.isEmpty) {
    throw StateError('The selected image could not be read.');
  }
  return File(path).readAsBytes();
}
