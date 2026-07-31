import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

import 'desktop_window_lifecycle.dart';

class DesktopAutostart {
  DesktopAutostart._();

  static bool _configured = false;

  static bool get isSupported => isDesktopPlatform;

  static void _configure() {
    if (_configured || !isDesktopPlatform) return;
    launchAtStartup.setup(
      appName: 'TorChat',
      appPath: Platform.resolvedExecutable,
    );
    _configured = true;
  }

  static Future<bool> isEnabled() async {
    if (!isDesktopPlatform) return false;
    _configure();
    return launchAtStartup.isEnabled();
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isDesktopPlatform) return;
    _configure();
    if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
