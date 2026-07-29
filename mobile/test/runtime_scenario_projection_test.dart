import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/runtime/runtime_payload.dart';

Map<String, dynamic> scenarios() => Map<String, dynamic>.from(
  jsonDecode(File('../common/client-runtime-scenarios.json').readAsStringSync())
      as Map,
);

void main() {
  test('shared runtime scenarios project through Flutter DTOs and events', () {
    final file = scenarios();
    expect(file['protocol'], 1);
    final scenariosList = file['scenarios'] as List;
    expect(scenariosList, isNotEmpty);

    for (final rawScenario in scenariosList.whereType<Map>()) {
      final scenario = Map<String, dynamic>.from(rawScenario);
      for (final event in (scenario['expectedEvents'] as List? ?? const [])) {
        RuntimePayload.fromMap(
          Map<String, dynamic>.from(event as Map),
        ).runtimeEvent();
      }
      final expectedFinalState = Map<String, dynamic>.from(
        scenario['expectedFinalState'] as Map? ?? const {},
      );
      for (final item
          in (expectedFinalState['messages'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(item as Map);
        ChatMessage.fromMap({
          'id': map['id'] ?? '00000000-0000-0000-0000-000000000001',
          'conversationId': map['conversationId'] ?? 'conversation',
          'outgoing': map['outgoing'] ?? true,
          'body': map['body'] ?? '',
          'state': map['state'] ?? 'QUEUED',
          'createdAt': map['createdAt'] ?? 42,
        });
      }
      for (final item
          in (expectedFinalState['conversations'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(item as Map);
        ConversationSummary.fromMap({
          'id': map['id'] ?? 'conversation',
          'contactInstallationId': map['contactInstallationId'] ?? 'peer',
          'status': map['status'] ?? 'ACTIVE',
          'lastMessagePreview': map['lastMessagePreview'] ?? '',
          'lastMessageAt': map['lastMessageAt'] ?? 42,
          'unreadCount': map['unreadCount'] ?? 0,
        });
      }
      for (final item in [
        ...((expectedFinalState['pairingInbox'] as List? ?? const [])),
        ...((expectedFinalState['pairingOutbox'] as List? ?? const [])),
      ]) {
        final map = Map<String, dynamic>.from(item as Map);
        PairingItem.fromMap({
          'pairingId': map['pairingId'] ?? 'pairing',
          'state': map['state'] ?? 'PENDING',
          'received': map['received'] ?? true,
          'expiresAt': map['expiresAt'] ?? 42,
          'availableActions': map['availableActions'] ?? const [],
        });
      }
    }
  });
}
