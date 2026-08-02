enum RuntimeProblemDisposition {
  fatal,
  connectionStatus,
  localOperation,
  diagnosticOnly,
}

final class RuntimeProblemClassification {
  const RuntimeProblemClassification({
    required this.disposition,
    required this.code,
  });

  final RuntimeProblemDisposition disposition;
  final String code;

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
      code: 'empty',
    );
  }

  if (normalized.contains('stale welcome') ||
      normalized.contains('duplicate welcome') ||
      normalized.contains('no matching key package') ||
      normalized.contains('starego zaproszenia') ||
      normalized.contains('duplicate invite has no pending welcome')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.diagnosticOnly,
      code: 'pairing_stale_welcome',
    );
  }

  if (normalized.contains('torka') ||
      normalized.contains('contact must be verified before sending') ||
      normalized.contains('bootstrap deferred until contact exists')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.diagnosticOnly,
      code: 'automation_deferred',
    );
  }

  if (normalized.contains('relay transport error') ||
      normalized.contains('relay bootstrap') ||
      normalized.contains('websocket') ||
      normalized.contains('connection reset') ||
      normalized.contains('tor unavailable') ||
      normalized.contains('network is offline')) {
    return const RuntimeProblemClassification(
      disposition: RuntimeProblemDisposition.connectionStatus,
      code: 'connection_recovering',
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
      code: 'runtime_fatal',
    );
  }

  return const RuntimeProblemClassification(
    disposition: RuntimeProblemDisposition.localOperation,
    code: 'operation_failed',
  );
}
