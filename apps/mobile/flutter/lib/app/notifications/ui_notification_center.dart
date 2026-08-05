import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'toast_message.dart';

final uiNotificationCenterProvider =
    NotifierProvider<UiNotificationCenter, ToastNotificationState>(
      UiNotificationCenter.new,
    );

class UiNotificationCenter extends Notifier<ToastNotificationState> {
  static const maxVisible = 3;
  static const exitDuration = Duration(milliseconds: 500);

  final Map<String, Timer> _timers = {};
  var _sequence = 0;

  @override
  ToastNotificationState build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const ToastNotificationState();
  }

  void showSuccess(String message, {required String deduplicationKey}) =>
      show(message, ToastKind.success, deduplicationKey: deduplicationKey);

  void showInfo(String message, {required String deduplicationKey}) =>
      show(message, ToastKind.info, deduplicationKey: deduplicationKey);

  void showWarning(String message, {required String deduplicationKey}) =>
      show(message, ToastKind.warning, deduplicationKey: deduplicationKey);

  void showError(String message, {required String deduplicationKey}) =>
      show(message, ToastKind.error, deduplicationKey: deduplicationKey);

  void show(
    String message,
    ToastKind kind, {
    required String deduplicationKey,
  }) {
    final normalized = message.trim();
    if (normalized.isEmpty || _contains(deduplicationKey)) return;
    final toast = ToastMessage(
      id: 'toast-${++_sequence}',
      deduplicationKey: deduplicationKey,
      message: normalized,
      kind: kind,
      duration: switch (kind) {
        ToastKind.success ||
        ToastKind.info => const Duration(milliseconds: 2800),
        ToastKind.warning => const Duration(seconds: 4),
        ToastKind.error => const Duration(seconds: 5),
      },
    );
    if (state.visible.length < maxVisible) {
      state = ToastNotificationState(
        visible: [...state.visible, toast],
        queued: state.queued,
      );
      _scheduleExit(toast);
    } else {
      state = ToastNotificationState(
        visible: state.visible,
        queued: [...state.queued, toast],
      );
    }
  }

  bool _contains(String key) =>
      state.visible.any((toast) => toast.deduplicationKey == key) ||
      state.queued.any((toast) => toast.deduplicationKey == key);

  void dismiss(String id) => _beginExit(id);

  void _scheduleExit(ToastMessage toast) {
    _timers[toast.id]?.cancel();
    _timers[toast.id] = Timer(toast.duration, () => _beginExit(toast.id));
  }

  void _beginExit(String id) {
    final index = state.visible.indexWhere((toast) => toast.id == id);
    if (index < 0 || state.visible[index].exiting) return;
    final visible = [...state.visible];
    visible[index] = visible[index].copyWith(exiting: true);
    state = ToastNotificationState(visible: visible, queued: state.queued);
    _timers[id]?.cancel();
    _timers[id] = Timer(exitDuration, () => _remove(id));
  }

  void _remove(String id) {
    _timers.remove(id)?.cancel();
    final visible = state.visible.where((toast) => toast.id != id).toList();
    final queued = [...state.queued];
    if (queued.isNotEmpty) {
      final promoted = queued.removeAt(0);
      visible.add(promoted);
      _scheduleExit(promoted);
    }
    state = ToastNotificationState(
      visible: List.unmodifiable(visible),
      queued: List.unmodifiable(queued),
    );
  }
}
