import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/torca_app.dart';
import 'platform/platform_services.dart';

export 'app/torca_app.dart' show ControllerHomePage, TorcaApp, TorChatMobileApp;

Future<void> main({PlatformServices? platformServices}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  final services = platformServices ?? PlatformServices();
  if (!await services.windowLifecycle.initialize()) return;
  runApp(TorcaApp(platformServices: services));
}
