import '../models/domain.dart';
import 'runtime_contract.dart';

class RuntimePayload {
  RuntimePayload(this._value);

  final Map<String, dynamic> _value;

  factory RuntimePayload.fromMap(Map<String, dynamic> value) =>
      RuntimePayload(Map<String, dynamic>.from(value));

  factory RuntimePayload.fromDynamic(Object? value) =>
      RuntimePayload.fromMap(Map<String, dynamic>.from(value as Map));

  static RuntimePayload? fromDynamicOrNull(Object? value) {
    if (value == null) return null;
    return RuntimePayload.fromDynamic(value);
  }

  static List<RuntimePayload> listFromDynamicOrNull(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => RuntimePayload.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  static List<RuntimePayload> itemsFromDynamicOrNull(Object? value) {
    if (value is Map && value['items'] is List) {
      return listFromDynamicOrNull(value['items']);
    }
    return listFromDynamicOrNull(value);
  }

  String? string(String key) => _value[key]?.toString();

  String stringOr(String key, String fallback) => string(key) ?? fallback;

  num? number(String key) => _value[key] as num?;

  int? intValue(String key) => number(key)?.toInt();

  Object? operator [](String key) => _value[key];

  Map<String, dynamic> toMap() => Map<String, dynamic>.from(_value);

  RuntimeIdentity identity() => RuntimeIdentity.fromMap(toMap());

  RuntimeProfile profile() => RuntimeProfile.fromMap(toMap());

  ContactRecord contact([String key = 'sender']) {
    final value = _value[key];
    final map = value is Map ? value : _value;
    return ContactRecord.fromMap(Map<String, dynamic>.from(map));
  }

  ConversationSummary conversation() => ConversationSummary.fromMap(toMap());

  ChatMessage message() => ChatMessage.fromMap(toMap());

  PairingItem pairingItem() => PairingItem.fromMap(toMap());

  InviteCode inviteCode() => InviteCode.fromMap(toMap());
  PairingPreparation pairingPreparation() =>
      PairingPreparation.fromMap(toMap());
  RuntimeSendEffect runtimeSendEffect() => RuntimeSendEffect.fromMap(toMap());
  PairingCancelEffect pairingCancelEffect() =>
      PairingCancelEffect.fromMap(toMap());

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
          final payload = Map<String, dynamic>.from(_value)
            ..remove(RuntimeContract.type);
          return DataChangedEvent(type, payload);
        }
        throw FormatException('unknown runtime event type: $type');
    }
  }
}
