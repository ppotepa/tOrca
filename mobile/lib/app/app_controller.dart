import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller_legacy.dart' as legacy;
import 'desktop_window_lifecycle.dart';
import 'notification_safe_app_controller.dart';

export 'app_controller_legacy.dart' hide appControllerProvider;

final appControllerProvider =
    NotifierProvider<NotificationSafeAppController, legacy.AppState>(() {
  unawaited(DesktopWindowLifecycle.initialize());
  return NotificationSafeAppController();
});
