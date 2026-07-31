import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller_legacy.dart' as legacy;
import 'sequential_app_controller.dart';

export 'app_controller_legacy.dart' hide appControllerProvider;

final appControllerProvider =
    NotifierProvider<legacy.AppController, legacy.AppState>(
  () => SequentialAppController(),
);
