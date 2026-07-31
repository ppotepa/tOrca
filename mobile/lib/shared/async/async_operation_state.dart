enum AsyncOperationPhase { idle, running, succeeded, failed }

final class AsyncOperationState {
  const AsyncOperationState({
    this.phase = AsyncOperationPhase.idle,
    this.label = '',
    this.targetId,
    this.error = '',
  });

  final AsyncOperationPhase phase;
  final String label;
  final String? targetId;
  final String error;

  bool get busy => phase == AsyncOperationPhase.running;
  bool get failed => phase == AsyncOperationPhase.failed;

  AsyncOperationState running({String? label, String? targetId}) =>
      AsyncOperationState(
        phase: AsyncOperationPhase.running,
        label: label ?? this.label,
        targetId: targetId ?? this.targetId,
      );

  AsyncOperationState succeeded({String? label, String? targetId}) =>
      AsyncOperationState(
        phase: AsyncOperationPhase.succeeded,
        label: label ?? this.label,
        targetId: targetId ?? this.targetId,
      );

  AsyncOperationState failedWith(
    Object value, {
    String? label,
    String? targetId,
  }) => AsyncOperationState(
    phase: AsyncOperationPhase.failed,
    label: label ?? this.label,
    targetId: targetId ?? this.targetId,
    error: value.toString(),
  );
}
