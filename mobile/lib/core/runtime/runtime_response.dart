import '../models/generated/runtime_models.g.dart';

class EngineResponse {
  const EngineResponse({
    required this.requestId,
    required this.ok,
    required this.result,
    this.errorCode,
    this.errorMessage,
  });

  final String requestId;
  final bool ok;
  final Object? result;
  final String? errorCode;
  final String? errorMessage;

  factory EngineResponse.fromDynamic(Object? value) {
    final response = GeneratedEngineResponse.fromDynamic(value);
    return EngineResponse(
      requestId: response.requestId,
      ok: response.ok,
      result: response.result,
      errorCode: response.errorCode,
      errorMessage: response.errorMessage,
    );
  }
}
