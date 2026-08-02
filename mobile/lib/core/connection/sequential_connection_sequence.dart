import 'connection_component.dart';

List<ConnectionComponentStatus> sequentialConnectionStatuses(
  List<ConnectionComponentStatus> raw,
) {
  final result = <ConnectionComponentStatus>[];
  ConnectionComponentStatus? blocking;

  for (final status in raw) {
    if (blocking != null) {
      result.add(
        ConnectionComponentStatus(
          component: status.component,
          state: ConnectionComponentState.pending,
          detail: 'Oczekiwanie na: ${blocking.component.title.toLowerCase()}',
        ),
      );
      continue;
    }

    if (status.ready) {
      result.add(status);
      continue;
    }

    final active = status.state == ConnectionComponentState.pending
        ? ConnectionComponentStatus(
            component: status.component,
            state: ConnectionComponentState.starting,
            detail: status.detail,
            progress: status.progress,
            attempt: status.attempt,
            errorCode: status.errorCode,
          )
        : status;
    result.add(active);
    blocking = active;
  }

  return List.unmodifiable(result);
}
