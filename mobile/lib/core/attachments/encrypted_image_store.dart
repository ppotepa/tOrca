import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const imageAutoDownloadPreferenceKey = 'torchat.images.autoDownload';

class ImageCacheUsage {
  const ImageCacheUsage({required this.files, required this.bytes});

  final int files;
  final int bytes;

  String get formattedBytes {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}

class ImageAttachmentPreferences {
  const ImageAttachmentPreferences._();

  static Future<bool> automaticDownloadEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    // Image payloads are already part of the end-to-end encrypted message.
    // "Download" only materializes that payload in the encrypted local cache,
    // so automatic delivery is the safe and expected default.
    return preferences.getBool(imageAutoDownloadPreferenceKey) ?? true;
  }

  static Future<void> setAutomaticDownloadEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(
      imageAutoDownloadPreferenceKey,
      value,
    );
    if (!saved) {
      throw StateError('Nie udało się zapisać ustawienia obrazów.');
    }
  }
}

typedef ImageStoreDirectoryProvider = Future<Directory> Function();
typedef ImageStoreKeyProvider = Future<SecretKey> Function();

class EncryptedImageStore {
  EncryptedImageStore({
    ImageStoreDirectoryProvider? directoryProvider,
    ImageStoreKeyProvider? keyProvider,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _keyProvider = keyProvider ?? _defaultKey;

  static final EncryptedImageStore instance = EncryptedImageStore();

  static const _keyName = 'torchat.attachmentStoreKey.v1';
  static const _extension = '.tca';
  static const _magic = <int>[0x54, 0x43, 0x49, 0x4d, 0x47, 0x31]; // TCIMG1
  static const _secureStorage = FlutterSecureStorage();

  final ImageStoreDirectoryProvider _directoryProvider;
  final ImageStoreKeyProvider _keyProvider;
  final AesGcm _cipher = AesGcm.with256bits();

  Future<void> _pending = Future<void>.value();

  Future<bool> contains(String messageId) =>
      _serialized(() async => (await _file(messageId)).exists());

  Future<Uint8List?> read(String messageId) => _serialized(() async {
    final file = await _file(messageId);
    if (!await file.exists()) return null;
    try {
      final payload = await file.readAsBytes();
      return await _decrypt(payload, messageId);
    } catch (_) {
      // A restored backup may contain files encrypted with an unavailable
      // platform key. Treat such files as disposable cache, never as chat
      // history, and let the inline encrypted message repopulate them.
      try {
        await file.delete();
      } catch (_) {
        // Cache cleanup is best effort. The failed read still returns null.
      }
      return null;
    }
  });

  Future<void> put(String messageId, Uint8List bytes) => _serialized(() async {
    if (messageId.trim().isEmpty) {
      throw const FormatException('Identyfikator wiadomości jest pusty.');
    }
    if (bytes.isEmpty) {
      throw const FormatException('Obraz jest pusty.');
    }
    final file = await _file(messageId);
    final encrypted = await _encrypt(bytes, messageId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(encrypted, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  });

  Future<void> remove(String messageId) => _serialized(() async {
    final file = await _file(messageId);
    if (await file.exists()) await file.delete();
  });

  Future<ImageCacheUsage> usage() => _serialized(() async {
    final directory = await _directory();
    var files = 0;
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith(_extension)) continue;
      files += 1;
      bytes += await entity.length();
    }
    return ImageCacheUsage(files: files, bytes: bytes);
  });

  Future<void> clear() => _serialized(() async {
    final directory = await _directoryProvider();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<File> _file(String messageId) async {
    final directory = await _directory();
    final safeId = messageId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${directory.path}${Platform.pathSeparator}$safeId$_extension');
  }

  Future<Directory> _directory() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Uint8List> _encrypt(Uint8List bytes, String messageId) async {
    final nonce = _randomBytes(12);
    final box = await _cipher.encrypt(
      bytes,
      secretKey: await _keyProvider(),
      nonce: nonce,
      aad: utf8.encode(messageId),
    );
    final builder = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(box.nonce.length)
      ..addByte(box.mac.bytes.length)
      ..add(box.nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return builder.takeBytes();
  }

  Future<Uint8List> _decrypt(Uint8List payload, String messageId) async {
    if (payload.length < _magic.length + 2) {
      throw const FormatException('Uszkodzony magazyn obrazów.');
    }
    for (var index = 0; index < _magic.length; index += 1) {
      if (payload[index] != _magic[index]) {
        throw const FormatException('Nieobsługiwana wersja magazynu obrazów.');
      }
    }
    var offset = _magic.length;
    final nonceLength = payload[offset++];
    final macLength = payload[offset++];
    final metadataLength = offset + nonceLength + macLength;
    if (nonceLength < 8 || macLength < 12 || metadataLength >= payload.length) {
      throw const FormatException('Uszkodzony zaszyfrowany obraz.');
    }
    final nonce = payload.sublist(offset, offset + nonceLength);
    offset += nonceLength;
    final mac = Mac(payload.sublist(offset, offset + macLength));
    offset += macLength;
    final box = SecretBox(payload.sublist(offset), nonce: nonce, mac: mac);
    final cleartext = await _cipher.decrypt(
      box,
      secretKey: await _keyProvider(),
      aad: utf8.encode(messageId),
    );
    return Uint8List.fromList(cleartext);
  }

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}encrypted-image-cache-v1',
    );
  }

  static Future<SecretKey> _defaultKey() async {
    final encoded = await _secureStorage.read(key: _keyName);
    if (encoded != null) {
      try {
        final bytes = base64Decode(encoded);
        if (bytes.length == 32) return SecretKey(bytes);
      } catch (_) {
        // Replace malformed key material below.
      }
    }
    final bytes = _randomBytes(32);
    await _secureStorage.write(key: _keyName, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
