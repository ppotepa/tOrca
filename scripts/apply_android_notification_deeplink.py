#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def change(rel: str, old: str, new: str) -> None:
    p = ROOT / rel
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{rel}: expected one match, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


service = "mobile/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt"
activity = "mobile/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt"
bridge = "mobile/lib/mobile_bridge.dart"

change(service, '''                postAlert(
                    title = notification.optString(EngineContract.TITLE).ifBlank { "TorChat" },
                    text = notification.optString(EngineContract.BODY).ifBlank { "Nowe zdarzenie" },
                    id = notification.optString(EngineContract.ID).hashCode(),
                )''', '''                postAlert(
                    title = notification.optString(EngineContract.TITLE).ifBlank { "TorChat" },
                    text = notification.optString(EngineContract.BODY).ifBlank { "Nowe zdarzenie" },
                    notificationId = notification.optString(EngineContract.ID),
                    conversationId = notification
                        .optString(EngineContract.CONVERSATION_ID)
                        .takeIf { it.isNotBlank() },
                )''')
change(service, '''    private fun postAlert(title: String, text: String, id: Int) {
        notifyIncomingNotification(
            context = this,
            title = title,
            text = text,
            notificationId = ALERT_NOTIFICATION_BASE + (id and 0x3fff),
        )
    }''', '''    private fun postAlert(
        title: String,
        text: String,
        notificationId: String,
        conversationId: String?,
    ) {
        notifyIncomingNotification(
            context = this,
            title = title,
            text = text,
            notificationId = notificationId,
            conversationId = conversationId,
        )
    }''')
change(service, '''        private const val ALERT_NOTIFICATION_BASE = 5100
''', '''        private const val ALERT_NOTIFICATION_BASE = 5100
        const val EXTRA_NOTIFICATION_ID = "org.torchat.extra.NOTIFICATION_ID"
        const val EXTRA_NATIVE_NOTIFICATION_ID = "org.torchat.extra.NATIVE_NOTIFICATION_ID"
        const val EXTRA_CONVERSATION_ID = "org.torchat.extra.CONVERSATION_ID"
''')
change(service, '''        private fun notifyIncomingNotification(
            context: Context,
            title: String,
            text: String,
            notificationId: Int,
        ) {''', '''        private fun notifyIncomingNotification(
            context: Context,
            title: String,
            text: String,
            notificationId: String,
            conversationId: String?,
        ) {''')
change(service, '''            if (!preferences.getBoolean("flutter.torchat.notifications.enabled", true)) return
            val sound = preferences.getBoolean("flutter.torchat.notifications.sound", true)''', '''            if (!preferences.getBoolean("flutter.torchat.notifications.enabled", true)) return
            val messageAlert = !conversationId.isNullOrBlank()
            val categoryEnabled = if (messageAlert) {
                preferences.getBoolean("flutter.torchat.notifications.messages", true)
            } else {
                preferences.getBoolean("flutter.torchat.notifications.pairing", true)
            }
            if (!categoryEnabled) return
            val nativeNotificationId = nativeNotificationId(notificationId)
            val sound = preferences.getBoolean("flutter.torchat.notifications.sound", true)''')
change(service, '''                    PendingIntent.getActivity(
                        context,
                        notificationId,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),''', '''                    PendingIntent.getActivity(
                        context,
                        nativeNotificationId,
                        Intent(context, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                            putExtra(EXTRA_NATIVE_NOTIFICATION_ID, nativeNotificationId)
                            conversationId?.let { putExtra(EXTRA_CONVERSATION_ID, it) }
                        },
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),''')
change(service, '''            context.getSystemService(NotificationManager::class.java)
                .notify(notificationId, notification)
        }

        private fun ensureIncomingNotificationChannel(context: Context) {''', '''            context.getSystemService(NotificationManager::class.java)
                .notify(nativeNotificationId, notification)
        }

        fun clearIncomingNotification(context: Context, notificationId: String) {
            val id = notificationId.trim()
            if (id.isEmpty()) return
            context.getSystemService(NotificationManager::class.java)
                .cancel(nativeNotificationId(id))
        }

        private fun nativeNotificationId(notificationId: String): Int =
            ALERT_NOTIFICATION_BASE + (notificationId.hashCode() and 0x3fff)

        private fun ensureIncomingNotificationChannel(context: Context) {''')

change(activity, '''    private var introPlayer: MediaPlayer? = null
''', '''    private var introPlayer: MediaPlayer? = null
    private var pendingConversationNavigation: Map<String, Any?>? = null
''')
change(activity, '''        ContextCompat.startForegroundService(this, serviceIntent)
        if (Build.VERSION.SDK_INT >= 33 &&''', '''        ContextCompat.startForegroundService(this, serviceIntent)
        handleNotificationIntent(intent)
        if (Build.VERSION.SDK_INT >= 33 &&''')
change(activity, '''                    TorChatForegroundService.runtimeSnapshot().forEach(sink::success)
                }''', '''                    TorChatForegroundService.runtimeSnapshot().forEach(sink::success)
                    pendingConversationNavigation?.let { navigation ->
                        sink.success(navigation)
                        pendingConversationNavigation = null
                    }
                }''')
change(activity, '''    private fun playIntro() {''', '''    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val notificationId = intent
            ?.getStringExtra(TorChatForegroundService.EXTRA_NOTIFICATION_ID)
            ?.trim()
            .orEmpty()
        if (notificationId.isEmpty()) return
        val nativeNotificationId = intent?.getIntExtra(
            TorChatForegroundService.EXTRA_NATIVE_NOTIFICATION_ID,
            -1,
        ) ?: -1
        if (nativeNotificationId >= 0) {
            getSystemService(android.app.NotificationManager::class.java)
                .cancel(nativeNotificationId)
        } else {
            TorChatForegroundService.clearIncomingNotification(this, notificationId)
        }
        val conversationId = intent
            ?.getStringExtra(TorChatForegroundService.EXTRA_CONVERSATION_ID)
            ?.trim()
            .orEmpty()
        intent?.removeExtra(TorChatForegroundService.EXTRA_NOTIFICATION_ID)
        intent?.removeExtra(TorChatForegroundService.EXTRA_NATIVE_NOTIFICATION_ID)
        intent?.removeExtra(TorChatForegroundService.EXTRA_CONVERSATION_ID)
        if (conversationId.isEmpty()) return
        val event = mapOf(
            EngineContract.TYPE to "conversation_navigation_requested",
            EngineContract.CONVERSATION_ID to conversationId,
            EngineContract.ID to notificationId,
        )
        val sink = eventSink
        if (sink == null) {
            pendingConversationNavigation = event
        } else {
            mainHandler.post { eventSink?.success(event) }
        }
    }

    private fun playIntro() {''')

change(bridge, '''import 'client_runtime.dart';
''', '''import 'app/conversation_navigation_intent.dart';
import 'client_runtime.dart';
''')
change(bridge, '''  Stream<RuntimeEvent> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((value) => RuntimePayload.fromDynamic(value).runtimeEvent());''', '''  Stream<RuntimeEvent> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((value) {
        final payload = RuntimePayload.fromDynamic(value);
        if (payload.string(EngineContract.type) ==
            'conversation_navigation_requested') {
          ConversationNavigationIntents.openConversation(
            conversationId: payload.string(EngineContract.conversationId) ?? '',
            notificationId: payload.string(EngineContract.id) ?? '',
          );
          return const RuntimeLogEvent(
            'Android notification navigation requested',
          );
        }
        return payload.runtimeEvent();
      });''')

print("Android notification deep-link patch applied")
