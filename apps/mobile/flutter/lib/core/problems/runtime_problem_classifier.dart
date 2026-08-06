import 'runtime_problem.dart';

enum RuntimeProblemDisposition {
  fatal,
  connectionStatus,
  localOperation,
  diagnosticOnly,
}

final class RuntimeProblemClassification {
  const RuntimeProblemClassification({
    required this.disposition,
    required this.problem,
  });

  final RuntimeProblemDisposition disposition;
  final RuntimeProblem problem;

  String get code => problem.code.wireValue;

  bool get userVisible => switch (disposition) {
    RuntimeProblemDisposition.fatal ||
    RuntimeProblemDisposition.localOperation => true,
    RuntimeProblemDisposition.connectionStatus ||
    RuntimeProblemDisposition.diagnosticOnly => false,
  };
}

RuntimeProblemClassification classifyRuntimeProblem(RuntimeProblem problem) {
  final disposition = switch (problem.category) {
    RuntimeErrorCategory.transport || RuntimeErrorCategory.availability =>
      RuntimeProblemDisposition.connectionStatus,
    RuntimeErrorCategory.persistence ||
    RuntimeErrorCategory.security => RuntimeProblemDisposition.fatal,
    RuntimeErrorCategory.validation ||
    RuntimeErrorCategory.domain => RuntimeProblemDisposition.localOperation,
    RuntimeErrorCategory.internal => RuntimeProblemDisposition.fatal,
  };

  return RuntimeProblemClassification(
    disposition: disposition,
    problem: problem,
  );
}
