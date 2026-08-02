import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller_base.dart' as base;
import 'desktop_window_lifecycle.dart';
import 'notification_safe_app_controller.dart';

export 'app_controller_base.dart';

final appControllerProvider =
    NotifierProvider<NotificationSafeAppController, base.AppState>(() {
      unawaited(DesktopWindowLifecycle.initialize());
      return NotificationSafeAppController();
    });
