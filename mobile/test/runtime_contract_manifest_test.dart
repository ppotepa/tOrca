import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/runtime/runtime_contract.dart';

Map<String, dynamic> manifest() => Map<String, dynamic>.from(
  jsonDecode(File('../common/client-engine-contract.json').readAsStringSync())
      as Map,
);

List<String> strings(Object? value) =>
    (value as List).map((item) => item.toString()).toList(growable: false);

void main() {
  test('Flutter RuntimeContract matches shared manifest', () {
    final contract = manifest();
    final methods = Map<String, dynamic>.from(contract['methods'] as Map);

    expect(strings(methods['public']), [
      RuntimeContract.bootstrap,
      RuntimeContract.connect,
      RuntimeContract.getIdentity,
      RuntimeContract.getProfile,
      RuntimeContract.pairingInbox,
      RuntimeContract.pairingOutbox,
      RuntimeContract.listContacts,
      RuntimeContract.listConversations,
      RuntimeContract.listMessages,
      RuntimeContract.setNickname,
      RuntimeContract.refreshPairingCode,
      RuntimeContract.submitPairingCode,
      RuntimeContract.acceptPairing,
      RuntimeContract.rejectPairing,
      RuntimeContract.archivePairing,
      RuntimeContract.cancelPairing,
      RuntimeContract.verifyContact,
      RuntimeContract.startConversation,
      RuntimeContract.openConversation,
      RuntimeContract.closeConversation,
      RuntimeContract.sendMessage,
      RuntimeContract.platformFact,
      RuntimeContract.shutdown,
    ]);
    expect(strings(contract['events']), [
      RuntimeContract.runtimeReady,
      RuntimeContract.torStatus,
      RuntimeContract.profileReady,
      RuntimeContract.inviteReceived,
      RuntimeContract.inviteStateChanged,
      RuntimeContract.messageReceived,
      RuntimeContract.messageStateChanged,
      RuntimeContract.conversationReadChanged,
      RuntimeContract.changed,
      RuntimeContract.runtimeError,
      RuntimeContract.runtimeLog,
    ]);
  });

  test('Flutter domain parsers accept only canonical manifest enum values', () {
    final contract = manifest();

    for (final value in strings(contract['messageStates'])) {
      expect(MessageState.fromValue(value).wireValue, value);
    }
    for (final value in strings(contract['conversationStates'])) {
      expect(
        ConversationSummary.fromMap({
          'id': 'c',
          'contactInstallationId': 'peer',
          'status': value,
        }).state.wireValue,
        value,
      );
    }
    for (final value in strings(contract['inviteStates'])) {
      expect(InviteState.fromValue(value).wireValue, value);
    }
    for (final value in strings(contract['pairingAvailableActions'])) {
      expect(PairingAvailableAction.fromValue(value).wireValue, value);
    }

    expect(() => MessageState.fromValue('PENDING'), throwsFormatException);
    expect(
      () => ConversationSummary.fromMap(const {
        'id': 'c',
        'contactInstallationId': 'peer',
        'status': 'NEW',
      }),
      throwsFormatException,
    );
    expect(() => InviteState.fromValue('CANCELED'), throwsFormatException);
  });
}
