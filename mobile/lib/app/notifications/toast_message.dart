enum ToastKind { success, info, warning, error }

final class ToastMessage {
  const ToastMessage({
    required this.id,
    required this.deduplicationKey,
    required this.message,
    required this.kind,
    required this.duration,
    this.exiting = false,
  });

  final String id;
  final String deduplicationKey;
  final String message;
  final ToastKind kind;
  final Duration duration;
  final bool exiting;

  ToastMessage copyWith({bool? exiting}) => ToastMessage(
    id: id,
    deduplicationKey: deduplicationKey,
    message: message,
    kind: kind,
    duration: duration,
    exiting: exiting ?? this.exiting,
  );
}

final class ToastNotificationState {
  const ToastNotificationState({
    this.visible = const [],
    this.queued = const [],
  });

  final List<ToastMessage> visible;
  final List<ToastMessage> queued;
}
