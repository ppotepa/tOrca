import 'dart:typed_data';

import 'package:gal/gal.dart';

class ImageGalleryService {
  const ImageGalleryService._();

  static Future<void> saveJpeg(
    Uint8List bytes, {
    required String messageId,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException('Obraz jest pusty.');
    }
    var hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      hasAccess = await Gal.requestAccess(toAlbum: true);
    }
    if (!hasAccess) {
      throw StateError('Brak uprawnień do zapisania obrazu w galerii.');
    }
    final safeId = messageId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    await Gal.putImageBytes(bytes, album: 'TorChat', name: 'torchat-$safeId');
  }
}
