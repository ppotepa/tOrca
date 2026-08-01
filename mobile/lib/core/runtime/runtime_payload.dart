import '../models/domain.dart';
import '../models/generated/runtime_models.g.dart';
import 'runtime_contract.dart';

class RuntimePayload {
  RuntimePayload(this._wire);

  final GeneratedRuntimePayload _wire;

  factory RuntimePayload.fromMap(Map<String, dynamic> value) =>
      RuntimePayload(GeneratedRuntimePayload.fromMap(value));

  factory RuntimePayload.fromDynamic(Object? value) =>
      RuntimePayload(GeneratedRuntimePayload.fromDynamic(value));

  static RuntimePayload? fromDynamicOrNull(Object? value) {
    final payload = GeneratedRuntimePayload.fromDynamicOrNull(value);
    return payload == null ? null : RuntimePayload(payload);
  }

  static List<RuntimePayload> listFromDynamicOrNull(Object? value) {
    return GeneratedRuntimePayload.listFromDynamicOrNull(
      value,
    ).map(RuntimePayload.new).toList();
  }

  static List<RuntimePayload> itemsFromDynamicOrNull(Object? value) {
    return GeneratedRuntimePayload.itemsFromDynamicOrNull(
      value,
    ).map(RuntimePayload.new).toList();
  }

  String? string(String key) => _wire.string(key);

  String stringOr(String key, String fallback) => string(key) ?? fallback;

  num? number(String key) => _wire.number(key);

  int? intValue(String key) => _wire.intValue(key);

  Object? operator [](String key) => _wire[key];

  Map<String, dynamic> toMap() => _wire.toMap();

  RuntimeIdentity identity() => RuntimeIdentity.fromMap(toMap());

  RuntimeProfile profile() => RuntimeProfile.fromMap(toMap());

  ContactRecord contact([String key = 'sender']) {
    final value = _wire[key];
    final map = value is Map ? Map<String, dynamic>.from(value) : toMap();
    return ContactRecord.fromMap(Map<String, dynamic>.from(map));
  }

  ConversationSummary conversation() => ConversationSummary.fromMap(toMap());

  ChatMessage message() => ChatMessage.fromMap(toMap());

  PairingItem pairingItem() => PairingItem.fromMap(toMap());

  InviteCode inviteCode() => InviteCode.fromMap(toMap());

  PeerEndpoint peerEndpoint() => PeerEndpoint.fromMap(toMap());

  RuntimeEvent runtimeEvent() {
    final type = string(EngineContract.type);
    switch (type) {
      case EngineContract.runtimeReady:
        return RuntimeReadyEvent(intValue(EngineContract.protocol) ?? 0);
      case EngineContract.torStatus:
        final phase = string(EngineContract.phase);
        return TorStatusEvent(
          RuntimeTorStatus(
            phase: TransportPhase.fromValue(phase),
            label: (string(EngineContract.label)?.trim().isNotEmpty ?? false)
                ? string(EngineContract.label)!
                : TransportPhase.fromValue(phase).label,
            detail: string(EngineContract.detail) ?? '',
            progress: intValue(EngineContract.progress),
            latencyMs: intValue(EngineContract.latencyMs),
            retryAttempt:
                intValue(EngineContract.retryAttempt) ??
                intValue(EngineContract.attempt) ??
                0,
          ),
        );
      case EngineContract.transportStatusChanged:
        return TransportStatusChangedEvent(
          TransportStatusSnapshot(
            component: TransportComponent.fromValue(
              string(EngineContract.transportComponent),
            ),
            state: TransportProbeState.fromValue(
              string(EngineContract.transportState),
            ),
            detail: string(EngineContract.detail) ?? '',
            progress: intValue(EngineContract.progress),
            latencyMs: intValue(EngineContract.latencyMs),
            retryAttempt: intValue(EngineContract.retryAttempt) ?? 0,
            retryInMs: intValue(EngineContract.retryInMs),
            generation: intValue(EngineContract.generation) ?? 0,
            endpoint: string(EngineContract.endpoint),
            updatedAt: intValue(EngineContract.updatedAt),
          ),
        );
      case EngineContract.profileReady:
        return ProfileReadyEvent(
          RuntimePayload.fromDynamicOrNull(
                this[EngineContract.profile],
              )?.profile() ??
              const RuntimeProfile(),
        );
      case EngineContract.runtimeError:
        return RuntimeErrorEvent(
          string(EngineContract.message) ?? 'Runtime error',
        );
      case EngineContract.runtimeLog:
        return RuntimeLogEvent(string(EngineContract.message) ?? '');
      case EngineContract.peerEndpointChanged:
        return PeerEndpointChangedEvent(
          contactId: string(EngineContract.contactId) ?? '',
          status: PeerEndpointStatus.fromValue(string(EngineContract.status)),
        );
      case EngineContract.peerConnectionChanged:
        return PeerConnectionChangedEvent(
          contactId: string(EngineContract.contactId) ?? '',
          status: PeerConnectionStatus.fromValue(string(EngineContract.status)),
          retryInMs:
              intValue('retryInMs') ?? intValue(EngineContract.retryInMs),
        );
      default:
        if (type == null || type.isEmpty) {
          throw FormatException('missing runtime event type');
        }
        if (type == EngineContract.changed ||
            type == EngineContract.inviteReceived ||
            type == EngineContract.inviteStateChanged ||
            type == EngineContract.messageReceived ||
            type == EngineContract.messageStateChanged ||
            type == EngineContract.conversationReadChanged ||
            type == EngineContract.typingChanged ||
            type == EngineContract.presenceChanged ||
            type == 'notification_opened') {
          final payload = toMap()..remove(EngineContract.type);
          return DataChangedEvent(type, payload);
        }
        throw FormatException('unknown runtime event type: $type');
    }
  }
}
