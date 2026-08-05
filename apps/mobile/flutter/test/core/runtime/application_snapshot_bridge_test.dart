import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/runtime/runtime_arguments.dart';
import 'package:torchat_mobile/core/runtime/runtime_bridge_base.dart';
import 'package:torchat_mobile/core/runtime/runtime_contract.dart';

final class _SnapshotBridge extends Object
    with RuntimeBridgeMethods
    implements RuntimeCallBridge {
  _SnapshotBridge(this.response);

  final Object? response;

  @override
  Stream<RuntimeEvent> get events => const Stream<RuntimeEvent>.empty();

  @override
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) async {
    expect(method, EngineContract.getApplicationSnapshot);
    return response;
  }
}

void main() {
  test('application snapshot decodes pairing lists from the same revision', () async {
    final bridge = _SnapshotBridge(<String, Object?>{
      'schemaVersion': 2,
      'generation': 17,
      'createdAtMs': 100,
      'identity': <String, Object?>{
        'installationId': 'local',
        'fingerprint': 'fp',
        'publicKey': 'pk',
      },
      'profile': <String, Object?>{
        'installationId': 'local',
        'nickname': 'Alice',
        'fingerprint': 'fp',
        'publicKey': 'pk',
      },
      'contacts': const <Object?>[],
      'conversations': const <Object?>[],
      'pairingInbox': <Object?>[
        <String, Object?>{
          'pairingId': 'incoming-1',
          'state': 'PENDING',
          'received': true,
          'expiresAt': 200,
          'availableActions': <String>['ACCEPT', 'REJECT'],
        },
      ],
      'pairingOutbox': <Object?>[
        <String, Object?>{
          'pairingId': 'outgoing-1',
          'state': 'ACCEPTED',
          'received': false,
          'expiresAt': 300,
          'availableActions': const <String>[],
        },
      ],
      'pairingSummary': <String, Object?>{
        'pendingInbox': 1,
        'pendingOutbox': 1,
      },
      'peerEndpointAvailable': true,
      'projection': <String, Object?>{
        'storeId': 'store-1',
        'engineSessionId': 'session-1',
        'revision': 17,
      },
    });

    final snapshot = await bridge.applicationSnapshot();

    expect(snapshot, isNotNull);
    expect(snapshot!.schemaVersion, 2);
    expect(snapshot.projectionStoreId, 'store-1');
    expect(snapshot.projectionSessionId, 'session-1');
    expect(snapshot.projectionRevision, 17);
    expect(snapshot.pairingInbox.single.id, 'incoming-1');
    expect(snapshot.pairingInbox.single.origin, PairingOrigin.inbox);
    expect(snapshot.pairingOutbox.single.id, 'outgoing-1');
    expect(snapshot.pairingOutbox.single.origin, PairingOrigin.outbox);
    expect(snapshot.pendingInbox, 1);
    expect(snapshot.pendingOutbox, 1);
  });

  test('schema one snapshot without pairing lists remains readable', () async {
    final bridge = _SnapshotBridge(<String, Object?>{
      'schemaVersion': 1,
      'identity': const <String, Object?>{},
      'contacts': const <Object?>[],
      'conversations': const <Object?>[],
      'pairingSummary': const <String, Object?>{},
    });

    final snapshot = await bridge.applicationSnapshot();

    expect(snapshot, isNotNull);
    expect(snapshot!.pairingInbox, isEmpty);
    expect(snapshot.pairingOutbox, isEmpty);
  });
}
