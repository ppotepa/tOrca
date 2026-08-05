import 'dart:async';

import '../platform_services.dart';

/// Compatibility event sink used by the mobile-owned window lifecycle.
/// Desktop composition supplies the full implementation from its runner.
class DesktopNavigationIntents {
  DesktopNavigationIntents._();

  static final StreamController<DesktopNavigationIntent> _controller =
      StreamController<DesktopNavigationIntent>.broadcast();

  static Stream<DesktopNavigationIntent> get stream => _controller.stream;

  static void openSettings() {
    _controller.add(DesktopNavigationIntent.openSettings);
  }
}
