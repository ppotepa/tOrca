import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'image_message_codec.dart';

const maximumSourceImageBytes = 20 * 1024 * 1024;

Future<List<PreparedImageAttachment>?> pickPreparedImageAttachments() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    allowMultiple: true,
    withData: true,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return null;
  if (result.files.length > 4) {
    throw StateError('Możesz wybrać maksymalnie 4 obrazy naraz.');
  }
  final prepared = <PreparedImageAttachment>[];
  for (final file in result.files) {
    final source = await _readBytes(file);
    if (source.lengthInBytes > maximumSourceImageBytes) {
      throw StateError('Obraz źródłowy może mieć maksymalnie 20 MiB.');
    }
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
    throw StateError('Nie udało się odczytać wybranego obrazu.');
  }
  return File(path).readAsBytes();
}
