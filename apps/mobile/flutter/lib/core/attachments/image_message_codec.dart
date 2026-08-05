import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'image_attachment_policy.dart';

const imageMessagePrefix = 'torchat-image-v1:';
const maximumImageAttachmentBytes = ImageAttachmentPolicy.maximumEncodedBytes;

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

  String toMessageBody() {
    ImageAttachmentPolicy.validateGeometry(
      width: width,
      height: height,
      frames: 1,
    );
    if (size <= 0 || size > ImageAttachmentPolicy.maximumEncodedBytes) {
      throw StateError('The prepared image exceeds the wire-size limit.');
    }
    final body = '$imageMessagePrefix${jsonEncode(<String, Object>{
      'mime': 'image/jpeg',
      'width': width,
      'height': height,
      'size': size,
      'data': base64Encode(bytes),
    })}';
    if (body.length > ImageAttachmentPolicy.maximumMessageBodyCharacters) {
      throw StateError('The prepared image message exceeds the wire limit.');
    }
    return body;
  }
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
  if (!isImageMessageBody(body) ||
      body.length > ImageAttachmentPolicy.maximumMessageBodyCharacters) {
    return null;
  }
  try {
    final payload = jsonDecode(body.substring(imageMessagePrefix.length));
    if (payload is! Map || payload['mime'] != 'image/jpeg') return null;

    final encoded = payload['data'];
    if (encoded is! String ||
        encoded.isEmpty ||
        encoded.length > ImageAttachmentPolicy.maximumEncodedDataCharacters) {
      return null;
    }
    final width = _intValue(payload['width']);
    final height = _intValue(payload['height']);
    final declaredSize = _intValue(payload['size']);
    if (!_geometryAllowed(width, height)) return null;
    if (declaredSize <= 0 ||
        declaredSize > ImageAttachmentPolicy.maximumEncodedBytes) {
      return null;
    }

    final bytes = Uint8List.fromList(base64Decode(encoded));
    if (bytes.lengthInBytes != declaredSize) return null;

    final decoder = image.findDecoderForData(bytes);
    if (decoder == null || decoder.format != image.ImageFormat.jpg) return null;
    final info = decoder.startDecode(bytes);
    if (info == null || info.numFrames != 1) return null;
    if (!_geometryAllowed(info.width, info.height)) return null;
    if (info.width != width || info.height != height) return null;

    return DecodedImageMessage(bytes: bytes, width: width, height: height);
  } catch (_) {
    return null;
  }
}

PreparedImageAttachment _prepareImageAttachment(
  Uint8List source,
  int maximumBytes,
) {
  ImageAttachmentPolicy.validateSourceLength(source.lengthInBytes);
  if (maximumBytes <= 0 ||
      maximumBytes > ImageAttachmentPolicy.maximumEncodedBytes) {
    throw ArgumentError.value(
      maximumBytes,
      'maximumBytes',
      'Must be within the Torca attachment wire limit.',
    );
  }

  final decoder = image.findDecoderForData(source);
  if (decoder == null ||
      !const <image.ImageFormat>{
        image.ImageFormat.jpg,
        image.ImageFormat.png,
        image.ImageFormat.webp,
      }.contains(decoder.format)) {
    throw const FormatException('The selected image format is unsupported.');
  }
  final info = decoder.startDecode(source);
  if (info == null) {
    throw const FormatException('The selected image is corrupted.');
  }
  ImageAttachmentPolicy.validateGeometry(
    width: info.width,
    height: info.height,
    frames: info.numFrames,
  );

  final decoded = decoder.decodeFrame(0);
  if (decoded == null) {
    throw const FormatException('The selected image could not be decoded.');
  }
  var working = image
      .bakeOrientation(decoded)
      .convert(numChannels: 3, noAnimation: true);
  ImageAttachmentPolicy.validateGeometry(
    width: working.width,
    height: working.height,
    frames: 1,
  );

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

bool _geometryAllowed(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= ImageAttachmentPolicy.maximumWidth &&
    height <= ImageAttachmentPolicy.maximumHeight &&
    width * height <= ImageAttachmentPolicy.maximumPixels;

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
