import '../models/generated/runtime_models.g.dart';

class EngineResponse {
  const EngineResponse({
    required this.requestId,
    required this.ok,
    required this.result,
    this.problem,
  });

  final String requestId;
  final bool ok;
  final Object? result;
  final GeneratedRuntimeProblem? problem;

  String? get errorCode => problem?.code;
  String? get errorCategory => problem?.category;
  bool get retryable => problem?.retryable ?? false;
  String? get operationId => problem?.operationId;
  String? get entityId => problem?.entityId;
  String? get diagnosticContext => problem?.diagnosticContext;

  factory EngineResponse.fromDynamic(Object? value) {
    final response = GeneratedEngineResponse.fromDynamic(value);
    return EngineResponse(
      requestId: response.requestId,
      ok: response.ok,
      result: response.result,
      problem: response.problem,
    );
  }
}
