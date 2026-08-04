import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

const imageMessagePrefix = 'torchat-image-v1:';
const maximumImageAttachmentBytes = 50 * 1024;

class PreparedImageAttachment {
  const PreparedImageAttachment({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  int get size => bytes.lengthInBytes;

  String toMessageBody() =>
      '$imageMessagePrefix${jsonEncode({'mime': 'image/jpeg', 'width': width, 'height': height, 'size': size, 'data': base64Encode(bytes)})}';
}

class DecodedImageMessage {
  const DecodedImageMessage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

Future<PreparedImageAttachment> prepareImageAttachment(
  Uint8List source, {
  int maximumBytes = maximumImageAttachmentBytes,
}) => Isolate.run(() => _prepareImageAttachment(source, maximumBytes));

bool isImageMessageBody(String body) => body.startsWith(imageMessagePrefix);

DecodedImageMessage? decodeImageMessageBody(String body) {
  if (!isImageMessageBody(body)) return null;
  try {
    final payload = jsonDecode(body.substring(imageMessagePrefix.length));
    if (payload is! Map) return null;
    if (payload['mime'] != 'image/jpeg') return null;
    final bytes = base64Decode(payload['data']?.toString() ?? '');
    final width = _intValue(payload['width']);
    final height = _intValue(payload['height']);
    final declaredSize = _intValue(payload['size']);
    if (bytes.isEmpty || width <= 0 || height <= 0) return null;
    if (bytes.lengthInBytes > maximumImageAttachmentBytes) return null;
    if (declaredSize != bytes.lengthInBytes) return null;
    return DecodedImageMessage(
      bytes: Uint8List.fromList(bytes),
      width: width,
      height: height,
    );
  } catch (_) {
    return null;
  }
}

PreparedImageAttachment _prepareImageAttachment(
  Uint8List source,
  int maximumBytes,
) {
  if (source.isEmpty) {
    throw const FormatException('The selected image is empty.');
  }
  final decoded = image.decodeImage(source);
  if (decoded == null) {
    throw const FormatException('The selected image is unsupported or corrupted.');
  }

  var working = image
      .bakeOrientation(decoded)
      .convert(numChannels: 3, noAnimation: true);
  const longSideCandidates = <int>[1280, 1024, 800, 640, 480, 360];
  const qualityCandidates = <int>[78, 70, 62, 54, 46, 38, 30];

  for (final longSide in longSideCandidates) {
    if (working.width > longSide || working.height > longSide) {
      working = working.width >= working.height
          ? image.copyResize(
              working,
              width: longSide,
              interpolation: image.Interpolation.average,
            )
          : image.copyResize(
              working,
              height: longSide,
              interpolation: image.Interpolation.average,
            );
    }
    for (final quality in qualityCandidates) {
      final encoded = image.encodeJpg(working, quality: quality);
      if (encoded.lengthInBytes <= maximumBytes) {
        return PreparedImageAttachment(
          bytes: Uint8List.fromList(encoded),
          width: working.width,
          height: working.height,
        );
      }
    }
  }

  throw StateError(
    'The image could not be reduced to ${maximumBytes ~/ 1024} KiB.',
  );
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}