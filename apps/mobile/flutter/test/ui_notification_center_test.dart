import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/app/notifications/ui_notification_center.dart';

void main() {
  test('shows at most three toasts and queues the rest in FIFO order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final center = container.read(uiNotificationCenterProvider.notifier);

    for (var index = 1; index <= 4; index++) {
      center.showInfo('Komunikat $index', deduplicationKey: 'toast-$index');
    }

    final state = container.read(uiNotificationCenterProvider);
    expect(state.visible.map((toast) => toast.message), [
      'Komunikat 1',
      'Komunikat 2',
      'Komunikat 3',
    ]);
    expect(state.queued.single.message, 'Komunikat 4');
  });

  test('deduplicates a notification while it is visible or queued', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final center = container.read(uiNotificationCenterProvider.notifier);

    center.showSuccess('Zaakceptowano', deduplicationKey: 'pairing:1:accepted');
    center.showSuccess('Zaakceptowano', deduplicationKey: 'pairing:1:accepted');

    final state = container.read(uiNotificationCenterProvider);
    expect(state.visible, hasLength(1));
    expect(state.queued, isEmpty);
  });

  test('dismissal promotes the oldest queued toast', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final center = container.read(uiNotificationCenterProvider.notifier);
    for (var index = 1; index <= 4; index++) {
      center.showInfo('Komunikat $index', deduplicationKey: 'toast-$index');
    }

    final first = container.read(uiNotificationCenterProvider).visible.first;
    center.dismiss(first.id);
    await Future<void>.delayed(UiNotificationCenter.exitDuration);

    final state = container.read(uiNotificationCenterProvider);
    expect(state.visible, hasLength(3));
    expect(state.visible.last.message, 'Komunikat 4');
    expect(state.queued, isEmpty);
  });
}
