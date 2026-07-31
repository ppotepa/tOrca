import 'dart:async';

enum DesktopNavigationIntent { openSettings }

class DesktopNavigationIntents {
  DesktopNavigationIntents._();

  static final StreamController<DesktopNavigationIntent> _controller =
      StreamController<DesktopNavigationIntent>.broadcast();

  static Stream<DesktopNavigationIntent> get stream => _controller.stream;

  static void openSettings() {
    _controller.add(DesktopNavigationIntent.openSettings);
  }
}
