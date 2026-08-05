import 'package:torchat_mobile/main.dart' as mobile_runner;
import 'package:torchat_mobile/platform/platform_services.dart';
import 'platform/desktop/desktop_autostart.dart';
import 'platform/desktop/desktop_navigation_intent.dart';
import 'platform/desktop/desktop_notification_service.dart';
import 'platform/desktop/desktop_profile_reset.dart';
import 'platform/desktop/desktop_window_lifecycle.dart';
import 'platform/desktop/windows_runtime.dart';

void main() {
  final runtime = WindowsRuntime();
  mobile_runner.main(
    platformServices: PlatformServices(
      runtimeBridgeFactory: () => runtime,
      navigation: DesktopNavigationIntents.instance,
      windowLifecycle: const DesktopWindowLifecycleService(),
      notifications: const DesktopNotificationAdapter(),
      autostart: const DesktopAutostartService(),
      profileReset: DesktopProfileResetService(
        stopRuntime: runtime.disposeRuntime,
      ),
    ),
  );
}
