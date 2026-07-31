import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller_legacy.dart' as legacy;
import 'notification_safe_app_controller.dart';

export 'app_controller_legacy.dart' hide appControllerProvider;

final appControllerProvider =
    NotifierProvider<legacy.AppController, legacy.AppState>(
  () => NotificationSafeAppController(),
);
