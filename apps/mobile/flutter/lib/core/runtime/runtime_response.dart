import '../models/generated/runtime_models.g.dart';
import '../problems/runtime_problem.dart';

class EngineResponse {
  const EngineResponse({
    required this.requestId,
    required this.ok,
    required this.result,
    this.errorCode,
    this.errorMessage,
    this.problem,
  });

  final String requestId;
  final bool ok;
  final Object? result;
  final String? errorCode;
  final String? errorMessage;
  final RuntimeProblem? problem;

  factory EngineResponse.fromDynamic(Object? value) {
    final response = GeneratedEngineResponse.fromDynamic(value);
    RuntimeProblem? problem;
    if (value is Map) {
      final envelope = Map<String, dynamic>.from(value);
      final result = envelope['result'];
      if (result is Map) {
        final problemValue = result['problem'];
        if (problemValue is Map) {
          problem = RuntimeProblem.fromJson(
            problemValue.map(
              (key, item) => MapEntry(key.toString(), item),
            ),
          );
        }
      }
    }
    return EngineResponse(
      requestId: response.requestId,
      ok: response.ok,
      result: response.result,
      errorCode: response.errorCode,
      errorMessage: response.errorMessage,
      problem: problem,
    );
  }
}
