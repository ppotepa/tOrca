import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/torca_app.dart';
import 'platform/platform_services.dart';

export 'app/torca_app.dart' show ControllerHomePage, TorcaApp, TorChatMobileApp;

Future<void> main({PlatformServices? platformServices}) async {
  if (platformServices != null) {
    PlatformServices.current = platformServices;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  if (!await PlatformServices.current.windowLifecycle.initialize()) return;
  runApp(const TorcaApp());
}
