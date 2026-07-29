import 'runtime_payload.dart';

class RuntimeResponse {
  const RuntimeResponse({
    required this.id,
    required this.ok,
    required this.payload,
    required this.result,
    this.error,
    this.eventType,
  });

  final String? id;
  final bool ok;
  final RuntimePayload payload;
  final Object? result;
  final String? error;
  final String? eventType;

  factory RuntimeResponse.fromDynamic(Object? value) {
    final payload = RuntimePayload.fromDynamic(value);
    return RuntimeResponse(
      id: payload.string('id'),
      ok: payload['ok'] == true,
      payload: payload,
      result: payload['result'],
      error: payload.string('error'),
      eventType: payload.string('type'),
    );
  }

  bool get isEvent => id == null;
  bool get isRuntimeErrorEvent => eventType == 'runtime_error';
}
