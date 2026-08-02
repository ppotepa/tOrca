package org.torchat.mobile

import android.content.Context
import org.json.JSONObject
import org.torchat.generated.EngineContract

internal object AndroidNotificationPolicy {
    @Volatile private var applicationContext: Context? = null

    fun initialize(context: Context) {
        applicationContext = context.applicationContext
    }

    fun shouldForward(event: JSONObject): Boolean {
        if (event.optString(EngineContract.TYPE) != EngineContract.EVENT_NOTIFICATION_REQUESTED) {
            return true
        }
        val notification = event.optJSONObject(EngineContract.NOTIFICATION) ?: return false
        val title = notification.optString(EngineContract.TITLE).trim()
        val body = notification.optString(EngineContract.BODY).trim()

        // This PairingOffer alert is a protocol finalization event, not
        // a newly committed incoming request. Reconnects can replay it.
        if (title == "Nowe zaproszenie" && body == "Masz nową prośbę o rozmowę.") {
            return false
        }

        val context = applicationContext ?: return true
        val preferences = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        if (!preferences.getBoolean("flutter.torchat.notifications.enabled", true)) {
            return false
        }

        return when {
            title == "Nowa wiadomość" -> preferences.getBoolean(
                "flutter.torchat.notifications.messages",
                true,
            )
            title.contains("zaproszenie", ignoreCase = true) -> preferences.getBoolean(
                "flutter.torchat.notifications.pairing",
                true,
            )
            else -> true
        }
    }
}
