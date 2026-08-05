import 'dart:async';

import 'package:torchat_mobile/platform/platform_services.dart';

class DesktopNavigationIntents implements NavigationIntentService {
  DesktopNavigationIntents._();

  static final DesktopNavigationIntents instance = DesktopNavigationIntents._();
  static final StreamController<DesktopNavigationIntent> _controller =
      StreamController<DesktopNavigationIntent>.broadcast();

  static Stream<DesktopNavigationIntent> get intentsStream => _controller.stream;

  static void openSettings() {
    _controller.add(DesktopNavigationIntent.openSettings);
  }

  @override
  Stream<DesktopNavigationIntent> get stream =>
      DesktopNavigationIntents.intentsStream;
}
