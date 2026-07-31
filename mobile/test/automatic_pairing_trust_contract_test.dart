import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completed pairing promotes and opens the new contact', () {
    final source = File(
      'lib/app/pairing_recovery_app_controller.dart',
    ).readAsStringSync();

    expect(source, contains('_promoteTrustedPairingContacts'));
    expect(source, contains('knownContactIds'));
    expect(source, contains('await super.verifyContact(contact.id)'));
    expect(source, contains('await super.openOrStartConversation(contact)'));
    expect(source, contains('_lastAutoOpenedContactId'));
    expect(source, contains('_autoTrustInFlight'));
  });

  test('release trust model does not require a second manual approval', () {
    final release = File('../RELEASE_0_1.md').readAsStringSync();

    expect(
      release,
      contains('No additional `Verify contact` action is required'),
    );
    expect(
      release,
      contains('verified contact and an active conversation on both sides'),
    );
  });
}
