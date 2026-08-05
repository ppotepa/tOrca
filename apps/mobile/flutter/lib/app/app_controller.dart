import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_services.dart';
import 'application_controller.dart';

export '../core/connection/app_state_connection.dart';
export 'application_controller.dart';
export 'application_state.dart';

final appControllerProvider =
    NotifierProvider<ApplicationController, AppState>(() {
      unawaited(PlatformServices.current.windowLifecycle.initialize());
      return ApplicationController();
    });
