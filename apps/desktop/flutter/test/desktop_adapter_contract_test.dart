import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop owns platform adapter implementations', () {
    const desktopAdapters = <String>[
      'lib/platform/desktop/windows_runtime.dart',
      'lib/platform/desktop/desktop_window_lifecycle.dart',
      'lib/platform/desktop/desktop_notification_service.dart',
      'lib/platform/desktop/desktop_autostart.dart',
      'lib/platform/desktop/desktop_navigation_intent.dart',
    ];

    for (final relativePath in desktopAdapters) {
      expect(File(relativePath).existsSync(), isTrue, reason: relativePath);
    }

    final mobileLib = Directory('../../mobile/flutter/lib');
    final forbidden = RegExp(
      r"platform/desktop/(windows_runtime|desktop_window_lifecycle|desktop_notification_service|desktop_autostart)\.dart",
    );
    final imports = <String>[];
    for (final entity in mobileLib.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        imports.addAll(
          entity
              .readAsLinesSync()
              .where((line) => line.contains('platform/desktop/')),
        );
      }
    }
    expect(imports.where(forbidden.hasMatch), isEmpty);
  });
}
