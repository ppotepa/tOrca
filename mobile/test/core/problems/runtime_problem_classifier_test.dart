import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/problems/runtime_problem_classifier.dart';

void main() {
  test('stale Welcome is diagnostic only', () {
    final result = classifyRuntimeProblem(
      'Nie można dokończyć starego zaproszenia. Poproś kontakt o nowy kod.',
    );
    expect(result.code, 'pairing_stale_welcome');
    expect(result.userVisible, isFalse);
  });

  test('relay recovery is represented by connection status', () {
    final result = classifyRuntimeProblem(
      'relay bootstrap retry 3 failed: relay transport error',
    );
    expect(result.code, 'connection_recovering');
    expect(result.userVisible, isFalse);
  });

  test('automation deferrals never reach the user', () {
    final result = classifyRuntimeProblem(
      'message poll deferred: contact must be verified before sending',
    );
    expect(result.code, 'automation_deferred');
    expect(result.userVisible, isFalse);
  });

  test('storage failures remain visible and fatal', () {
    final result = classifyRuntimeProblem('SQLite integrity_check failed');
    expect(result.code, 'runtime_fatal');
    expect(result.userVisible, isTrue);
  });

  test('ordinary operation errors remain local and visible', () {
    final result = classifyRuntimeProblem('Nieprawidłowy kod parowania');
    expect(result.code, 'operation_failed');
    expect(result.userVisible, isTrue);
  });
}
