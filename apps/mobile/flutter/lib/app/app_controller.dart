import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application_controller.dart';

export '../core/connection/app_state_connection.dart';
export 'application_controller.dart';
export 'application_state.dart';

final appControllerProvider =
    NotifierProvider<ApplicationController, AppState>(ApplicationController.new);
