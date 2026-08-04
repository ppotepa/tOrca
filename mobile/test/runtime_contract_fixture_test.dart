import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/runtime/runtime_payload.dart';

void main() {
  RuntimeFixture fixture() => RuntimeFixture.fromMap(
    Map<String, dynamic>.from(
      jsonDecode(
            File('../common/internal-runtime-fixtures.json').readAsStringSync(),
          )
          as Map,
    ),
  );

  test('shared runtime fixture parses canonical DTOs and events', () {
    final data = fixture();
    final identity = data.identity;
    final profile = data.profile;

    expect(identity.installationId, 'installation-alice');
    expect(profile.nickname, 'Alice');
    expect(data.contact.verified, isTrue);
    expect(data.conversation.state, ConversationState.active);
    expect(data.message.state, MessageState.delivered);
    expect(data.pairingCode.code, 'amber-birch-cobalt-dawn-ember-fjord');
    expect(data.pairingInboxItem.received, isTrue);
    expect(data.pairingOutboxItem.received, isFalse);
    expect(data.pairingInboxItem.can(PairingAvailableAction.accept), isTrue);
    expect(data.pairingOutboxItem.can(PairingAvailableAction.cancel), isTrue);

    final ready =
        RuntimePayload.fromMap(data.events.first).runtimeEvent()
            as RuntimeReadyEvent;
    expect(ready.protocol, 1);

    final status =
        RuntimePayload.fromMap(data.events[1]).runtimeEvent() as TorStatusEvent;
    expect(status.snapshot.retryAttempt, 0);

    final eventTypes = data.events
        .map((item) => RuntimePayload.fromMap(item).runtimeEvent())
        .map((event) => event.runtimeType.toString())
        .toList();

    expect(eventTypes, contains('TorStatusEvent'));
    expect(eventTypes, contains('ProfileReadyEvent'));
    expect(eventTypes, contains('RuntimeErrorEvent'));
    expect(eventTypes, contains('RuntimeLogEvent'));
  });
}
