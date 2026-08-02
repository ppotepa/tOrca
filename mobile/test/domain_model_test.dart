import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/runtime/runtime_arguments.dart';
import 'package:torchat_mobile/core/runtime/runtime_line.dart';
import 'package:torchat_mobile/core/runtime/runtime_payload.dart';

void main() {
  test('transport snapshot treats degraded as usable but not connected', () {
    const snapshot = RuntimeTorStatus(phase: TransportPhase.degraded);

    expect(snapshot.connected, isFalse);
    expect(snapshot.warning, isTrue);
    expect(snapshot.usable, isTrue);
    expect(snapshot.failed, isFalse);
    expect(snapshot.busy, isFalse);
  });

  test('shared model exposes canonical labels and phase flags', () {
    expect(TransportPhase.connected.isConnected, isTrue);
    expect(TransportPhase.bootstrapping.isConnecting, isTrue);
    expect(TransportPhase.offline.isError, isTrue);
    expect(TransportPhase.connected.label, 'Połączono z relayem przez Tor');
    expect(TransportPhase.error.label, 'Sprawdzanie połączenia Tor');
    expect(ConversationState.active.presenceLabel, 'online');
    expect(ConversationState.failed.presenceLabel, 'niedostępny');
    expect(InviteState.accepted.label, 'Zaakceptowane, finalizacja kontaktu');
    expect(MessageState.delivered.label, 'dostarczono');
  });

  test('invite and pairing request expose pending state through status', () {
    const invite = PairingItem(
      id: 'invite-1',
      peer: ContactRecord(
        id: 'peer-1',
        nickname: 'Peer',
        fingerprint: 'fp',
        publicKey: 'pk',
        verified: true,
      ),
      status: InviteState.pending,
      availableActions: [PairingAvailableAction.accept],
    );
    const request = PairingItem(
      id: 'pair-1',
      status: InviteState.pending,
      availableActions: [PairingAvailableAction.cancel],
    );

    expect(invite.can(PairingAvailableAction.accept), isTrue);
    expect(request.can(PairingAvailableAction.cancel), isTrue);
  });

  test('runtime event decoder accepts generic dynamic maps', () {
    final event = RuntimePayload.fromMap({
      'type': 'tor_status',
      'phase': 'connected',
      'label': 'Gotowe',
      'detail': 'relay ready',
      'progress': 100,
      'latencyMs': 25,
      'retryAttempt': 2,
    }).runtimeEvent();

    expect(event, isA<TorStatusEvent>());
    final torStatus = (event as TorStatusEvent).snapshot;
    expect(torStatus.phase, TransportPhase.connected);
    expect(torStatus.label, 'Gotowe');
    expect(torStatus.detail, 'relay ready');
    expect(torStatus.progress, 100);
    expect(torStatus.latencyMs, 25);
    expect(torStatus.retryAttempt, 2);
  });

  test('runtime payload exposes typed accessors for tor status events', () {
    final payload = RuntimePayload.fromMap({
      'type': 'tor_status',
      'phase': 'connected',
      'label': 'Gotowe',
      'detail': 'relay ready',
      'progress': 100,
      'latencyMs': 25,
      'retryAttempt': 2,
    });

    expect(payload.string('phase'), 'connected');
    expect(payload.intValue('progress'), 100);

    final event = payload.runtimeEvent();
    expect(event, isA<TorStatusEvent>());
  });

  test('runtime payload maps peer endpoint bundle into typed model', () {
    final endpoint = RuntimePayload.fromMap({
      'installationId': 'install-1',
      'onionAddress':
          'abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcd.onion',
      'virtualPort': 443,
      'sequence': 7,
      'issuedAt': 123456,
      'capabilities': ['peer_message_v1'],
    }).peerEndpoint();

    expect(endpoint.installationId, 'install-1');
    expect(endpoint.virtualPort, 443);
    expect(endpoint.sequence, 7);
    expect(endpoint.capabilities, ['peer_message_v1']);
  });

  test(
    'runtime payload decodes typed peer status events from runtime fields',
    () {
      final endpointEvent = RuntimePayload.fromMap({
        'type': 'peer_endpoint_changed',
        'contactId': 'contact-1',
        'status': 'VERIFIED',
      }).runtimeEvent();
      expect(endpointEvent, isA<PeerEndpointChangedEvent>());
      expect(
        (endpointEvent as PeerEndpointChangedEvent).status,
        PeerEndpointStatus.verified,
      );

      final connectionEvent = RuntimePayload.fromMap({
        'type': 'peer_connection_changed',
        'contactId': 'contact-1',
        'status': 'BACKOFF',
        'retryInMs': 2500,
      }).runtimeEvent();
      expect(connectionEvent, isA<PeerConnectionChangedEvent>());
      final typedEvent = connectionEvent as PeerConnectionChangedEvent;
      expect(typedEvent.status, PeerConnectionStatus.backoff);
      expect(typedEvent.retryInMs, 2500);
    },
  );

  test('runtime line preserves runtime error event payload', () {
    final line = EngineLine.parse(
      '{"type":"runtime","event":{"type":"runtime_error","message":"relay stopped"}}',
    );

    expect(line, isA<EngineRuntimeEventLine>());
    final event = (line as EngineRuntimeEventLine).payload.runtimeEvent();
    expect(event, isA<RuntimeErrorEvent>());
    expect((event as RuntimeErrorEvent).message, 'relay stopped');
  });

  test('runtime line parser distinguishes responses, events and bad json', () {
    final response = EngineLine.parse(
      '{"type":"response","requestId":"1","result":{"status":"ok","payload":{"type":"json","value":{"hello":"world"}}}}',
    );
    expect(response, isA<EngineResponseLine>());

    final event = EngineLine.parse(
      '{"type":"runtime","event":{"type":"runtime_log","message":"hello"}}',
    );
    expect(event, isA<EngineRuntimeEventLine>());

    final bad = EngineLine.parse('not-json');
    expect(bad, isA<EngineParseErrorLine>());
  });

  test('runtime arguments preserve canonical bridge keys', () {
    expect(RuntimeArguments.nickname('Ada').toMap(), {'nickname': 'Ada'});
    expect(RuntimeArguments.message('msg-1', 'hello').toMap(), {
      'id': 'msg-1',
      'text': 'hello',
    });
  });

  test('runtime value maps records and lists without helper maps', () {
    final payload = RuntimePayload.fromMap({
      'nickname': 'Alice',
      'fingerprint': 'fp',
      'publicKey': 'pk',
      'verification': 'VERIFIED',
      'id': 'contact-1',
      'installationId': 'contact-1',
    });

    expect(payload.contact().nickname, 'Alice');

    final list = RuntimePayload.listFromDynamicOrNull([
      {
        'nickname': 'Alice',
        'fingerprint': 'fp',
        'publicKey': 'pk',
        'verification': 'VERIFIED',
        'id': 'contact-1',
        'installationId': 'contact-1',
      },
    ]).map((entry) => entry.contact()).toList();
    expect(list, hasLength(1));
    expect(list.first.nickname, 'Alice');
  });

  test('identity mapper preserves canonical runtime identity fields', () {
    final identity = RuntimePayload.fromMap({
      'installationId': 'install-1',
      'fingerprint': 'fp-1',
      'publicKey': 'pk-1',
    }).identity();

    expect(identity.installationId, 'install-1');
    expect(identity.fingerprint, 'fp-1');
    expect(identity.publicKey, 'pk-1');
  });

  test('runtime identity promotes into profile with nickname', () {
    const identity = RuntimeIdentity(
      installationId: 'install-1',
      fingerprint: 'fp-1',
      publicKey: 'pk-1',
    );

    final profile = identity.toProfile('Alice');

    expect(profile.installationId, identity.installationId);
    expect(profile.fingerprint, identity.fingerprint);
    expect(profile.publicKey, identity.publicKey);
    expect(profile.nickname, 'Alice');
  });

  test('status helper normalizes and detects pending values', () {
    expect(InviteState.fromValue(' pending '), InviteState.pending);
    expect(InviteState.fromValue('accepted'), InviteState.accepted);
  });

  test('message state parser rejects obsolete aliases and unknown values', () {
    expect(MessageState.fromValue('QUEUED'), MessageState.queued);
    expect(() => MessageState.fromValue('PENDING'), throwsFormatException);
    expect(() => MessageState.fromValue('unknown'), throwsFormatException);
  });

  test('conversation state parser rejects obsolete and unknown values', () {
    expect(
      ConversationSummary.fromMap(const {
        'id': 'conversation-1',
        'contactInstallationId': 'peer-1',
        'status': 'PENDING',
      }).state,
      ConversationState.pending,
    );
    expect(
      () => ConversationSummary.fromMap(const {
        'id': 'conversation-1',
        'contactInstallationId': 'peer-1',
        'status': 'NEW',
      }),
      throwsFormatException,
    );
    expect(
      () => ConversationSummary.fromMap(const {
        'id': 'conversation-1',
        'contactInstallationId': 'peer-1',
        'status': 'unknown',
      }),
      throwsFormatException,
    );
  });

  test(
    'startup transitions allow late readiness updates and keep error terminal',
    () {
      var steps = initialStartupSteps();
      steps = transitionStartupStep(
        steps,
        StartupStepKind.engine,
        StartupStepState.running,
        'engine',
      );
      final rejectedTor = transitionStartupStep(
        steps,
        StartupStepKind.tor,
        StartupStepState.running,
        'tor',
      );
      expect(rejectedTor[2].state, StartupStepState.running);

      steps = transitionStartupStep(
        steps,
        StartupStepKind.engine,
        StartupStepState.error,
        'migration failed',
      );
      final lateTor = transitionStartupStep(
        steps,
        StartupStepKind.tor,
        StartupStepState.ready,
        'late event',
      );
      expect(lateTor.first.state, StartupStepState.error);
      expect(lateTor[1].state, StartupStepState.blocked);
      expect(
        lateTor.where((step) => step.state == StartupStepState.running),
        isEmpty,
      );

      final recoveredEngine = transitionStartupStep(
        steps,
        StartupStepKind.engine,
        StartupStepState.ready,
        'recovered',
      );
      expect(recoveredEngine.first.state, StartupStepState.ready);
      expect(recoveredEngine.first.detail, 'recovered');

      final blockedPeer = transitionStartupStep(
        steps,
        StartupStepKind.peerListener,
        StartupStepState.ready,
        'late peer',
      );
      expect(blockedPeer.first.state, StartupStepState.error);
      expect(blockedPeer[3].state, StartupStepState.blocked);
    },
  );
}
