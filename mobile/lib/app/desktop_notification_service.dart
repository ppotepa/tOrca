import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/models/domain.dart';
import 'conversation_navigation_intent.dart';
import 'desktop_window_lifecycle.dart';
import '../locales/generated/app_localizations.dart';
import '../locales/domain/app_locale_preference.dart';

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

    final processed =
        preferences.getStringList(_notificationDeduplicationKey) ??
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
    final storedLocale = AppLocalePreference.fromStorage(
      preferences.getString('torchat.locale.preference'),
    );
    final systemLocale = PlatformDispatcher.instance.locale;
    final locale = storedLocale?.locale ??
        (AppLocalizations.supportedLocales.any(
              (candidate) => candidate.languageCode == systemLocale.languageCode,
            )
            ? Locale(systemLocale.languageCode)
            : const Locale('en'));
    final l10n = await AppLocalizations.delegate.load(locale);
    final title = switch (event.kind) {
      NotificationKind.messageReceived => l10n.notificationNewMessageTitle,
      NotificationKind.pairingRequest => l10n.notificationPairingRequestTitle,
      NotificationKind.pairingCompleted => l10n.pairingCompletedTitle,
    };
    final body = switch (event.kind) {
      NotificationKind.messageReceived => showPreview &&
              (event.previewText?.trim().isNotEmpty ?? false)
          ? event.previewText!.trim()
          : l10n.notificationPrivateMessageBody,
      NotificationKind.pairingRequest => l10n.notificationPairingRequestBody,
      NotificationKind.pairingCompleted => l10n.pairingCompletedDescription,
    };
    final notification = LocalNotification(
      identifier: id,
      title: title,
      body: body,
      silent: true,
    );
    notification.onClick = () {
      unawaited(DesktopWindowLifecycle.instance.showWindow());
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
