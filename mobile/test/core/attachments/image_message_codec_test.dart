import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:torchat_mobile/core/attachments/image_message_codec.dart';

void main() {
  test('prepares a metadata-free image no larger than 50 KiB', () async {
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
    source.exif.imageDescription = 'private metadata';

    final prepared = await prepareImageAttachment(
      Uint8List.fromList(image.encodePng(source)),
    );

    expect(prepared.size, lessThanOrEqualTo(maximumImageAttachmentBytes));
    expect(prepared.width, greaterThan(0));
    expect(prepared.height, greaterThan(0));

    final decodedJpeg = image.decodeJpg(prepared.bytes);
    expect(decodedJpeg, isNotNull);
    expect(decodedJpeg!.exif.isEmpty, isTrue);
  });

  test('message body round-trips and validates declared size', () async {
    final source = image.Image(width: 16, height: 16);
    image.fill(source, color: image.ColorRgb8(20, 40, 60));
    final prepared = await prepareImageAttachment(
      Uint8List.fromList(image.encodePng(source)),
    );

    final body = prepared.toMessageBody();
    final decoded = decodeImageMessageBody(body);

    expect(isImageMessageBody(body), isTrue);
    expect(decoded, isNotNull);
    expect(decoded!.bytes, prepared.bytes);
    expect(decoded.width, prepared.width);
    expect(decoded.height, prepared.height);
  });

  test('rejects malformed and oversized image messages', () {
    expect(decodeImageMessageBody('hello'), isNull);
    expect(decodeImageMessageBody('${imageMessagePrefix}{}'), isNull);

    final oversized = PreparedImageAttachment(
      bytes: Uint8List(maximumImageAttachmentBytes + 1),
      width: 1,
      height: 1,
    ).toMessageBody();
    expect(decodeImageMessageBody(oversized), isNull);
  });
}
