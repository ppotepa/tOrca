import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'image_message_codec.dart';

const maximumSourceImageBytes = 20 * 1024 * 1024;

Future<PreparedImageAttachment?> pickPreparedImageAttachment() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    allowMultiple: false,
    withData: true,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return null;

  final file = result.files.single;
  final source = await _readBytes(file);
  if (source.lengthInBytes > maximumSourceImageBytes) {
    throw StateError('Obraz źródłowy może mieć maksymalnie 20 MiB.');
  }
  return prepareImageAttachment(source);
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
