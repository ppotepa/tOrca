import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client runtime exposes capability boundaries without dynamic dispatch', () {
    final contract = File('lib/client_runtime.dart').readAsStringSync();
    final capabilities = File(
      'lib/runtime_capabilities.dart',
    ).readAsStringSync();
    final clientStart = contract.indexOf('abstract class ClientRuntime');
    final wrapperStart = contract.indexOf('final class _SessionAwareClientRuntime');
    final clientContract = contract.substring(clientStart, wrapperStart);

    expect(clientContract, contains('RuntimeLifecycleCapability'));
    expect(clientContract, contains('RuntimePairingCapability'));
    expect(clientContract, contains('RuntimeConversationCapability'));
    expect(clientContract, contains('RuntimeMessagingCapability'));
    expect(contract.contains('as dynamic'), isFalse);
    expect(clientContract.contains('listPairings'), isFalse);
    expect(clientContract.contains('pairingInbox'), isFalse);
    expect(clientContract.contains('pairingOutbox'), isFalse);
    expect(contract.contains('async {}'), isFalse);
    expect(capabilities, contains('RuntimePairingQueryCapability'));
    expect(capabilities, contains('RuntimeProjectionCapability'));
  });
}
