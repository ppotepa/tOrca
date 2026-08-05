import 'package:flutter/services.dart';

import 'runtime_problem.dart';

RuntimeProblem runtimeProblemFromError(Object error) {
  if (error is RuntimeProblem) return error;
  if (error is PlatformException) {
    final details = error.details;
    if (details is Map) {
      return RuntimeProblem.fromJson(
        details.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return RuntimeProblem(
      code: RuntimeErrorCode.parse(error.code),
      category: _categoryForCode(RuntimeErrorCode.parse(error.code)),
      retryable: false,
      diagnosticContext: error.message,
    );
  }
  if (error is Map) {
    return RuntimeProblem.fromJson(
      error.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
  return RuntimeProblem(
    code: RuntimeErrorCode.internal,
    category: RuntimeErrorCategory.internal,
    retryable: false,
    diagnosticContext: error.runtimeType.toString(),
  );
}

RuntimeErrorCategory _categoryForCode(RuntimeErrorCode code) => switch (code) {
      RuntimeErrorCode.invalidInput => RuntimeErrorCategory.validation,
      RuntimeErrorCode.notFound || RuntimeErrorCode.conflict =>
        RuntimeErrorCategory.domain,
      RuntimeErrorCode.temporarilyUnavailable || RuntimeErrorCode.unsupported =>
        RuntimeErrorCategory.availability,
      RuntimeErrorCode.transportUnavailable => RuntimeErrorCategory.transport,
      RuntimeErrorCode.storageFailed => RuntimeErrorCategory.persistence,
      RuntimeErrorCode.cryptoFailed => RuntimeErrorCategory.security,
      RuntimeErrorCode.internal => RuntimeErrorCategory.internal,
    };
