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
  test('Flutter EngineContract matches shared manifest', () {
    final contract = manifest();
    final methods = Map<String, dynamic>.from(contract['methods'] as Map);

    expect(strings(methods['public']), [
      EngineContract.bootstrap,
      EngineContract.connect,
      EngineContract.getIdentity,
      EngineContract.getProfile,
      EngineContract.pairingInbox,
      EngineContract.pairingOutbox,
      EngineContract.listContacts,
      EngineContract.listConversations,
      EngineContract.listMessages,
      EngineContract.getPeerEndpoint,
      EngineContract.retryPeerConnection,
      EngineContract.rotatePeerEndpoint,
      EngineContract.setNickname,
      EngineContract.refreshPairingCode,
      EngineContract.submitPairingCode,
      EngineContract.acceptPairing,
      EngineContract.rejectPairing,
      EngineContract.archivePairing,
      EngineContract.cancelPairing,
      EngineContract.verifyContact,
      EngineContract.updateContactSettings,
      EngineContract.startConversation,
      EngineContract.openConversation,
      EngineContract.closeConversation,
      EngineContract.sendMessage,
      EngineContract.retryMessage,
      EngineContract.deleteMessageLocal,
      EngineContract.setTyping,
      EngineContract.setPresence,
      EngineContract.sendReadReceipts,
      EngineContract.platformFact,
      EngineContract.shutdown,
    ]);
    expect(strings(contract['events']), [
      EngineContract.runtimeReady,
      EngineContract.torStatus,
      EngineContract.profileReady,
      EngineContract.inviteReceived,
      EngineContract.inviteStateChanged,
      EngineContract.messageReceived,
      EngineContract.messageStateChanged,
      EngineContract.conversationReadChanged,
      EngineContract.typingChanged,
      EngineContract.presenceChanged,
      EngineContract.peerEndpointChanged,
      EngineContract.peerConnectionChanged,
      EngineContract.changed,
      EngineContract.runtimeError,
      EngineContract.runtimeLog,
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
