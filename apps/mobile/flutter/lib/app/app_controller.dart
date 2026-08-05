import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller_base.dart' as base;
import '../platform/platform_services.dart';
import 'notification_safe_app_controller.dart';

export '../core/connection/app_state_connection.dart';
export 'app_controller_base.dart';

final appControllerProvider =
    NotifierProvider<NotificationSafeAppController, base.AppState>(() {
      unawaited(PlatformServices.current.windowLifecycle.initialize());
      return NotificationSafeAppController();
    });
