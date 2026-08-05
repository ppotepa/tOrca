enum RuntimeErrorCode {
  invalidInput('invalid_input'),
  notFound('not_found'),
  conflict('conflict'),
  temporarilyUnavailable('temporarily_unavailable'),
  transportUnavailable('transport_unavailable'),
  storageFailed('storage_failed'),
  cryptoFailed('crypto_failed'),
  unsupported('unsupported'),
  internal('internal');

  const RuntimeErrorCode(this.wireValue);
  final String wireValue;

  static RuntimeErrorCode parse(String value) => values.firstWhere(
        (candidate) => candidate.wireValue == value,
        orElse: () => RuntimeErrorCode.internal,
      );
}

enum RuntimeErrorCategory {
  validation('validation'),
  domain('domain'),
  transport('transport'),
  persistence('persistence'),
  security('security'),
  availability('availability'),
  internal('internal');

  const RuntimeErrorCategory(this.wireValue);
  final String wireValue;

  static RuntimeErrorCategory parse(String value) => values.firstWhere(
        (candidate) => candidate.wireValue == value,
        orElse: () => RuntimeErrorCategory.internal,
      );
}

final class RuntimeProblem {
  const RuntimeProblem({
    required this.code,
    required this.category,
    required this.retryable,
    this.operationId,
    this.entityId,
    this.diagnosticContext,
  });

  factory RuntimeProblem.fromJson(Map<String, Object?> json) {
    return RuntimeProblem(
      code: RuntimeErrorCode.parse(json['code'] as String? ?? 'internal'),
      category: RuntimeErrorCategory.parse(
        json['category'] as String? ?? 'internal',
      ),
      retryable: json['retryable'] as bool? ?? false,
      operationId: json['operationId'] as String?,
      entityId: json['entityId'] as String?,
      diagnosticContext: json['diagnosticContext'] as String?,
    );
  }

  final RuntimeErrorCode code;
  final RuntimeErrorCategory category;
  final bool retryable;
  final String? operationId;
  final String? entityId;
  final String? diagnosticContext;
}
