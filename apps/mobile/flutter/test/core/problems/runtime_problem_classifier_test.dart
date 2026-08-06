import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/problems/runtime_problem.dart';
import 'package:torchat_mobile/core/problems/runtime_problem_classifier.dart';

RuntimeProblem _problem(
  RuntimeErrorCategory category, {
  RuntimeErrorCode code = RuntimeErrorCode.internal,
}) => RuntimeProblem(code: code, category: category, retryable: false);

void main() {
  test('transport and availability problems map to connection status', () {
    for (final category in [
      RuntimeErrorCategory.transport,
      RuntimeErrorCategory.availability,
    ]) {
      final result = classifyRuntimeProblem(_problem(category));
      expect(result.disposition, RuntimeProblemDisposition.connectionStatus);
      expect(result.userVisible, isFalse);
    }
  });

  test('persistence and security problems remain fatal', () {
    for (final category in [
      RuntimeErrorCategory.persistence,
      RuntimeErrorCategory.security,
    ]) {
      final result = classifyRuntimeProblem(_problem(category));
      expect(result.disposition, RuntimeProblemDisposition.fatal);
      expect(result.userVisible, isTrue);
    }
  });

  test('validation and domain problems are local and visible', () {
    for (final category in [
      RuntimeErrorCategory.validation,
      RuntimeErrorCategory.domain,
    ]) {
      final result = classifyRuntimeProblem(_problem(category));
      expect(result.disposition, RuntimeProblemDisposition.localOperation);
      expect(result.userVisible, isTrue);
    }
  });

  test('internal problems remain fatal', () {
    final result = classifyRuntimeProblem(
      _problem(RuntimeErrorCategory.internal),
    );
    expect(result.disposition, RuntimeProblemDisposition.fatal);
    expect(result.userVisible, isTrue);
  });

  test('classification exposes the structured code wire value', () {
    final result = classifyRuntimeProblem(
      _problem(
        RuntimeErrorCategory.persistence,
        code: RuntimeErrorCode.storageFailed,
      ),
    );
    expect(result.code, 'storage_failed');
  });
}
