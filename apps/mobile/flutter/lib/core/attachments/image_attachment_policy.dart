abstract final class ImageAttachmentPolicy {
  static const maximumAttachmentsPerMessage = 4;
  static const maximumSourceBytes = 12 * 1024 * 1024;
  static const maximumEncodedBytes = 50 * 1024;
  static const maximumWidth = 8192;
  static const maximumHeight = 8192;
  static const maximumPixels = 24 * 1024 * 1024;
  static const maximumFrames = 1;

  // JPEG bytes are base64 encoded inside a small JSON envelope. Keeping a
  // separate wire limit prevents oversized JSON/base64 allocation before the
  // declared attachment size can be validated.
  static const maximumEncodedDataCharacters =
      ((maximumEncodedBytes + 2) ~/ 3) * 4;
  static const maximumMessageBodyCharacters =
      maximumEncodedDataCharacters + 512;

  static void validateSourceLength(int bytes) {
    if (bytes <= 0) {
      throw const FormatException('The selected image is empty.');
    }
    if (bytes > maximumSourceBytes) {
      throw StateError(
        'A source image can be at most ${maximumSourceBytes ~/ (1024 * 1024)} MiB.',
      );
    }
  }

  static void validateGeometry({
    required int width,
    required int height,
    required int frames,
  }) {
    if (width <= 0 || height <= 0) {
      throw const FormatException('The selected image has invalid dimensions.');
    }
    if (width > maximumWidth || height > maximumHeight) {
      throw StateError(
        'The selected image dimensions exceed ${maximumWidth}×$maximumHeight.',
      );
    }
    if (width * height > maximumPixels) {
      throw StateError(
        'The selected image exceeds the ${maximumPixels ~/ (1024 * 1024)} megapixel safety limit.',
      );
    }
    if (frames < 1 || frames > maximumFrames) {
      throw const StateError('Animated images are not supported.');
    }
  }
}
