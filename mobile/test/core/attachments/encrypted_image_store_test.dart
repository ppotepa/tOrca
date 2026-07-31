import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/attachments/encrypted_image_store.dart';

void main() {
  late Directory directory;
  late EncryptedImageStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('torchat-image-store-');
    store = EncryptedImageStore(
      directoryProvider: () async => directory,
      keyProvider: () async => SecretKey(List<int>.filled(32, 7)),
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('round trips encrypted attachment without plaintext on disk', () async {
    final cleartext = Uint8List.fromList(
      List<int>.generate(2048, (index) => index % 251),
    );

    await store.put('message-1', cleartext);

    expect(await store.contains('message-1'), isTrue);
    expect(await store.read('message-1'), cleartext);
    final files = await directory.list().where((item) => item is File).toList();
    expect(files, hasLength(1));
    final encrypted = await (files.single as File).readAsBytes();
    expect(encrypted, isNot(contains(cleartext.sublist(0, 32))));

    final usage = await store.usage();
    expect(usage.files, 1);
    expect(usage.bytes, encrypted.length);
  });

  test('removes individual files and clears the complete cache', () async {
    await store.put('message-1', Uint8List.fromList([1, 2, 3]));
    await store.put('message-2', Uint8List.fromList([4, 5, 6]));

    await store.remove('message-1');
    expect(await store.contains('message-1'), isFalse);
    expect(await store.contains('message-2'), isTrue);

    await store.clear();
    final usage = await store.usage();
    expect(usage.files, 0);
    expect(usage.bytes, 0);
  });

  test('different key treats cache as disposable and removes corrupt file', () async {
    await store.put('message-1', Uint8List.fromList([9, 8, 7, 6]));
    final other = EncryptedImageStore(
      directoryProvider: () async => directory,
      keyProvider: () async => SecretKey(List<int>.filled(32, 8)),
    );

    expect(await other.read('message-1'), isNull);
    expect(await other.contains('message-1'), isFalse);
  });
}
