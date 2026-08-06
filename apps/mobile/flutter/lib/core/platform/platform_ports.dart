import '../../client_runtime.dart';
import '../../locales/domain/app_locale_preference.dart';

enum DesktopNavigationIntent { openSettings }

abstract interface class WindowLifecycleService {
  Future<bool> initialize();

  Future<void> showWindow();

  Future<void> refreshLocale(AppLocalePreference preference);
}

abstract interface class NotificationService {
  Future<void> show(
    NotificationRequestedEvent event, {
    required String? selectedConversationId,
  });

  Future<void> clear(String notificationId);
}

abstract interface class NavigationIntentService {
  Stream<DesktopNavigationIntent> get stream;
}

abstract interface class AutostartService {
  bool get isSupported;

  Future<bool> isEnabled();

  Future<void> setEnabled(bool enabled);
}

typedef RuntimeBridgeFactory = ClientRuntime Function();
