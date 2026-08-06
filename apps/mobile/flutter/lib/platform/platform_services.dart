import 'dart:async';
import 'dart:io';

import '../core/platform/platform_ports.dart';
import 'android/mobile_bridge.dart';
import 'diagnostics_export_service.dart';
import 'profile_reset_service.dart';
import 'update_check_service.dart';

export '../core/platform/platform_ports.dart';

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

final class DefaultWindowLifecycleService implements WindowLifecycleService {
  const DefaultWindowLifecycleService();

  @override
  Future<bool> initialize() => Future<bool>.value(true);

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> refreshLocale(preference) async {}
}

final class DefaultNotificationService implements NotificationService {
  const DefaultNotificationService();

  @override
  Future<void> show(
    event, {
    required String? selectedConversationId,
  }) async {}

  @override
  Future<void> clear(String notificationId) async {}
}

final class DefaultNavigationIntentService
    implements NavigationIntentService {
  const DefaultNavigationIntentService();

  static final Stream<DesktopNavigationIntent> _stream =
      const Stream<DesktopNavigationIntent>.empty();

  @override
  Stream<DesktopNavigationIntent> get stream => _stream;
}

final class PlatformServices {
  PlatformServices({
    WindowLifecycleService? windowLifecycle,
    NotificationService? notifications,
    NavigationIntentService? navigation,
    RuntimeBridgeFactory? runtimeBridgeFactory,
    AutostartService? autostart,
    DiagnosticsExportService? diagnostics,
    ProfileResetService? profileReset,
    UpdateCheckService? updates,
  })  : windowLifecycle = windowLifecycle ?? const DefaultWindowLifecycleService(),
        notifications = notifications ?? const DefaultNotificationService(),
        navigation = navigation ?? const DefaultNavigationIntentService(),
        runtimeBridgeFactory = runtimeBridgeFactory ?? MobileBridge.new,
        autostart = autostart ?? const DefaultAutostartService(),
        diagnostics = diagnostics ?? const LocalDiagnosticsExportService(),
        profileReset = profileReset ?? const MobileProfileResetService(),
        updates = updates ?? const LocalSignedUpdateCheckService();

  final WindowLifecycleService windowLifecycle;
  final NotificationService notifications;
  final NavigationIntentService navigation;
  final RuntimeBridgeFactory runtimeBridgeFactory;
  final AutostartService autostart;
  final DiagnosticsExportService diagnostics;
  final ProfileResetService profileReset;
  final UpdateCheckService updates;
}

final class DefaultAutostartService implements AutostartService {
  const DefaultAutostartService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool enabled) async {}
}
