import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:torchat_mobile/core/attachments/image_attachment_policy.dart';
import 'package:torchat_mobile/core/attachments/image_message_codec.dart';

void main() {
  test('re-encodes an image no larger than the wire limit', () async {
    final source = image.Image(width: 640, height: 480, numChannels: 4);
    for (var y = 0; y < source.height; y += 1) {
      for (var x = 0; x < source.width; x += 1) {
        source.setPixelRgba(
          x,
          y,
          (x * 13 + y * 7) % 256,
          (x * 3 + y * 17) % 256,
          (x * 19 + y * 5) % 256,
          255,
        );
      }
    }

    final sourceBytes = Uint8List.fromList(image.encodePng(source));
    final prepared = await prepareImageAttachment(sourceBytes);

    expect(prepared.size, lessThanOrEqualTo(maximumImageAttachmentBytes));
    expect(prepared.width, greaterThan(0));
    expect(prepared.height, greaterThan(0));
    expect(prepared.bytes, isNot(sourceBytes));
    expect(image.decodeJpg(prepared.bytes), isNotNull);
  });

  test('message body round-trips and validates the actual JPEG header', () async {
    final source = image.Image(width: 16, height: 16);
    image.fill(source, color: image.ColorRgb8(20, 40, 60));
    final prepared = await prepareImageAttachment(
      Uint8List.fromList(image.encodePng(source)),
    );

    final body = prepared.toMessageBody();
    final decoded = decodeImageMessageBody(body);

    expect(isImageMessageBody(body), isTrue);
    expect(body.length, lessThanOrEqualTo(
      ImageAttachmentPolicy.maximumMessageBodyCharacters,
    ));
    expect(decoded, isNotNull);
    expect(decoded!.bytes, prepared.bytes);
    expect(decoded.width, prepared.width);
    expect(decoded.height, prepared.height);
  });

  test('rejects malformed, forged and oversized image messages', () {
    expect(decodeImageMessageBody('hello'), isNull);
    expect(decodeImageMessageBody('$imageMessagePrefix{}'), isNull);

    expect(
      () => PreparedImageAttachment(
        bytes: Uint8List(maximumImageAttachmentBytes + 1),
        width: 1,
        height: 1,
      ).toMessageBody(),
      throwsStateError,
    );

    final forged = '$imageMessagePrefix${jsonEncode(<String, Object>{
      'mime': 'image/jpeg',
      'width': 1,
      'height': 1,
      'size': 4,
      'data': base64Encode(const <int>[1, 2, 3, 4]),
    })}';
    expect(decodeImageMessageBody(forged), isNull);

    final oversizedBody =
        '$imageMessagePrefix${'x' * ImageAttachmentPolicy.maximumMessageBodyCharacters}';
    expect(decodeImageMessageBody(oversizedBody), isNull);
  });

  test('policy rejects decompression-bomb geometry and animation', () {
    expect(
      () => ImageAttachmentPolicy.validateGeometry(
        width: ImageAttachmentPolicy.maximumWidth + 1,
        height: 1,
        frames: 1,
      ),
      throwsStateError,
    );
    expect(
      () => ImageAttachmentPolicy.validateGeometry(
        width: 6000,
        height: 6000,
        frames: 1,
      ),
      throwsStateError,
    );
    expect(
      () => ImageAttachmentPolicy.validateGeometry(
        width: 100,
        height: 100,
        frames: 2,
      ),
      throwsStateError,
    );
  });

  test('rejects formats outside JPEG PNG and WebP', () async {
    final source = image.Image(width: 8, height: 8);
    final bmp = Uint8List.fromList(image.encodeBmp(source));
    expect(prepareImageAttachment(bmp), throwsFormatException);
  });
}
