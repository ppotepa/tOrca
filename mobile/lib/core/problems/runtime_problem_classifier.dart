enum RuntimeProblemDisposition {
  fatal,
  connectionStatus,
  localOperation,
  diagnosticOnly,
}

enum RuntimeProblemCode {
  empty('empty'),
  pairingStaleWelcome('pairing_stale_welcome'),
  automationDeferred('automation_deferred'),
  connectionRecovering('connection_recovering'),
  runtimeFatal('runtime_fatal'),
  operationFailed('operation_failed');

  const RuntimeProblemCode(this.wireValue);
  final String wireValue;
}

final class RuntimeProblemClassification {
  const RuntimeProblemClassification({
    required this.disposition,
    required this.problemCode,
  });

  final RuntimeProblemDisposition disposition;
  final RuntimeProblemCode problemCode;
  String get code => problemCode.wireValue;

  bool get userVisible => switch (disposition) {
    RuntimeProblemDisposition.fatal ||
    RuntimeProblemDisposition.localOperation => true,
    RuntimeProblemDisposition.connectionStatus ||
    RuntimeProblemDisposition.diagnosticOnly => false,
  };
}

RuntimeProblemClassification classifyRuntimeProblem(String message) {
  final normalized = message.trim().toLowerCase();

  if (normalized.isEmpty) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.diagnosticOnly,
      problemCode: RuntimeProblemCode.empty,
    );
  }

  if (normalized.contains('stale welcome') ||
      normalized.contains('duplicate welcome') ||
      normalized.contains('no matching key package') ||
      normalized.contains('starego zaproszenia') ||
      normalized.contains('duplicate invite has no pending welcome')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.diagnosticOnly,
      problemCode: RuntimeProblemCode.pairingStaleWelcome,
    );
  }

  if (normalized.contains('torka') ||
      normalized.contains('contact must be verified before sending') ||
      normalized.contains('bootstrap deferred until contact exists')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.diagnosticOnly,
      problemCode: RuntimeProblemCode.automationDeferred,
    );
  }

  if (normalized.contains('relay transport error') ||
      normalized.contains('relay http 502') ||
      normalized.contains('relay http 503') ||
      normalized.contains('relay http 504') ||
      normalized.contains('bad gateway') ||
      normalized.contains('gateway timeout') ||
      normalized.contains('relay bootstrap') ||
      normalized.contains('websocket') ||
      normalized.contains('connection reset') ||
      normalized.contains('tor unavailable') ||
      normalized.contains('network is offline')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.connectionStatus,
      problemCode: RuntimeProblemCode.connectionRecovering,
    );
  }

  if (normalized.contains('sqlite') ||
      normalized.contains('database') ||
      normalized.contains('integrity_check') ||
      normalized.contains('private key') ||
      normalized.contains('engine actor failed') ||
      normalized.contains('engine_fatal')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.fatal,
      problemCode: RuntimeProblemCode.runtimeFatal,
    );
  }

  return const RuntimeProblemClassification(
    disposition: RuntimeProblemDisposition.localOperation,
    problemCode: RuntimeProblemCode.operationFailed,
  );
}
