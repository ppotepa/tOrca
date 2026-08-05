import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completed pairing is not promoted or opened by Flutter', () {
    final appSources = Directory('lib/app')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(appSources, isNot(contains('_promoteTrustedPairingContacts')));
    expect(appSources, isNot(contains('_retryWelcomeProjectionIfNeeded')));
    expect(appSources, isNot(contains('_lastAutoOpenedContactId')));
    expect(appSources, isNot(contains('verifyContact(contact.id)')));
  });

  test('release trust model is completed by the Rust pairing workflow', () {
    final enginePairing = File(
      '../../../packages/torchat-client-engine/src/actor/pairing.rs',
    ).readAsStringSync();
    final release = File('../../../README.md').readAsStringSync();

    expect(enginePairing, contains('BeginVerified'));
    expect(enginePairing, contains('put_conversation_mls_snapshot'));
    expect(enginePairing, contains('put_pending_welcome'));
    expect(
      release,
      contains('No additional `Verify contact` action is required'),
    );
    expect(release, contains('verified contact and an active'));
  });
}
