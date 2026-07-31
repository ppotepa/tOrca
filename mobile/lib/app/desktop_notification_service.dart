import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import 'conversation_navigation_intent.dart';
import 'desktop_window_lifecycle.dart';

const _notificationDeduplicationKey =
    'torchat.notifications.desktop.processedIds';
const _maximumRememberedNotificationIds = 256;

class DesktopNotificationService {
  DesktopNotificationService._();

  static bool _initialized = false;
  static final Map<String, LocalNotification> _visible =
      <String, LocalNotification>{};

  static Future<void> show(
    NotificationRequestedEvent event, {
    required String? selectedConversationId,
  }) async {
    if (!isDesktopPlatform) return;

    final id = event.id.trim();
    final conversationId = event.conversationId?.trim() ?? '';
    if (id.isEmpty || conversationId.isEmpty) return;
    if (conversationId == selectedConversationId) return;

    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('torchat.notifications.enabled') ?? true) ||
        !(preferences.getBool('torchat.notifications.messages') ?? true)) {
      return;
    }

    final processed = preferences.getStringList(_notificationDeduplicationKey) ??
        const <String>[];
    if (processed.contains(id)) return;
    final updated = <String>[...processed, id];
    if (updated.length > _maximumRememberedNotificationIds) {
      updated.removeRange(
        0,
        updated.length - _maximumRememberedNotificationIds,
      );
    }
    await preferences.setStringList(_notificationDeduplicationKey, updated);

    await _ensureInitialized();
    final showPreview =
        preferences.getBool('torchat.notifications.preview') ?? false;
    final sound = preferences.getBool('torchat.notifications.sound') ?? true;
    final notification = LocalNotification(
      identifier: id,
      title: event.title.trim().isEmpty ? 'TorChat' : event.title.trim(),
      body: showPreview ? event.body : 'Nowa zaszyfrowana wiadomość',
      silent: !sound,
    );
    notification.onClick = () {
      DesktopWindowLifecycle.instance.showWindow();
      ConversationNavigationIntents.openConversation(
        conversationId: conversationId,
        notificationId: id,
      );
      _visible.remove(id);
    };
    notification.onClose = (_) => _visible.remove(id);
    _visible[id] = notification;
    await notification.show();
  }

  static Future<void> clear(String notificationId) async {
    final id = notificationId.trim();
    if (id.isEmpty) return;
    final notification = _visible.remove(id);
    if (notification != null) await notification.close();
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await localNotifier.setup(
      appName: 'TorChat',
      shortcutPolicy: Platform.isWindows
          ? ShortcutPolicy.requireCreate
          : ShortcutPolicy.ignore,
    );
    _initialized = true;
  }
}
