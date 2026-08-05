import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application state has one notifier and no controller inheritance chain', () {
    const removed = <String>[
      'lib/app/app_controller_base.dart',
      'lib/app/sequential_app_controller.dart',
      'lib/app/presentation_app_controller.dart',
      'lib/app/notification_safe_app_controller.dart',
    ];

    for (final path in removed) {
      expect(File(path).existsSync(), isFalse, reason: '$path must stay removed');
    }

    final provider = File('lib/app/app_controller.dart').readAsStringSync();
    expect(provider, contains('NotifierProvider<ApplicationController, AppState>'));
    expect(provider.contains('NotificationSafeAppController'), isFalse);

    final controller = File(
      'lib/app/application_controller.dart',
    ).readAsStringSync();
    expect(controller, contains('class ApplicationController extends Notifier<AppState>'));
    expect(controller, contains('ApplicationRuntimeCoordinator'));
    expect(controller, contains('ApplicationNotificationCoordinator'));
    expect(controller.contains('extends SequentialAppController'), isFalse);
    expect(controller.contains('extends PresentationAppController'), isFalse);
  });
}
