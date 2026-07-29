import '../models/generated/runtime_models.g.dart';
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
    final response = GeneratedRuntimeResponse.fromDynamic(value);
    final payload = RuntimePayload(response.payload);
    return RuntimeResponse(
      id: response.id,
      ok: response.ok,
      payload: payload,
      result: response.result,
      error: response.error,
      eventType: response.eventType,
    );
  }

  bool get isEvent => id == null;
  bool get isRuntimeErrorEvent => eventType == 'runtime_error';
}
