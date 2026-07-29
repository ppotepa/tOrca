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
    return GeneratedRuntimePayload.listFromDynamicOrNull(value)
        .map(RuntimePayload.new)
        .toList();
  }

  static List<RuntimePayload> itemsFromDynamicOrNull(Object? value) {
    return GeneratedRuntimePayload.itemsFromDynamicOrNull(value)
        .map(RuntimePayload.new)
        .toList();
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

  RuntimeEvent runtimeEvent() {
    final type = string(RuntimeContract.type);
    switch (type) {
      case RuntimeContract.runtimeReady:
        return RuntimeReadyEvent(intValue('protocol') ?? 0);
      case RuntimeContract.torStatus:
        final phase = string('phase');
        return TorStatusEvent(
          RuntimeTorStatus(
            phase: TransportPhase.fromValue(phase),
            label: (string('label')?.trim().isNotEmpty ?? false)
                ? string('label')!
                : TransportPhase.fromValue(phase).label,
            detail: string('detail') ?? '',
            progress: intValue('progress'),
            latencyMs: intValue('latencyMs'),
            retryAttempt: intValue('retryAttempt') ?? intValue('attempt') ?? 0,
          ),
        );
      case RuntimeContract.profileReady:
        return ProfileReadyEvent(
          RuntimePayload.fromDynamicOrNull(this['profile'])?.profile() ??
              const RuntimeProfile(),
        );
      case RuntimeContract.runtimeError:
        return RuntimeErrorEvent(string('message') ?? 'Runtime error');
      case RuntimeContract.runtimeLog:
        return RuntimeLogEvent(string('message') ?? '');
      default:
        if (type == null || type.isEmpty) {
          throw FormatException('missing runtime event type');
        }
        if (type == RuntimeContract.changed ||
            type == RuntimeContract.inviteReceived ||
            type == RuntimeContract.inviteStateChanged ||
            type == RuntimeContract.messageReceived ||
            type == RuntimeContract.messageStateChanged ||
            type == RuntimeContract.conversationReadChanged) {
          final payload = toMap()
            ..remove(RuntimeContract.type);
          return DataChangedEvent(type, payload);
        }
        throw FormatException('unknown runtime event type: $type');
    }
  }
}
