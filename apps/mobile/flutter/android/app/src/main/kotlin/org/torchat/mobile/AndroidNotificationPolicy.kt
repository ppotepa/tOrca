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
        val kind = notification.optString(EngineContract.KIND).trim()

        // This PairingOffer alert is a protocol finalization event, not
        // a newly committed incoming request. Reconnects can replay it.
        if (kind == "pairing_completed") {
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

        return when (kind) {
            "message_received" -> preferences.getBoolean(
                "flutter.torchat.notifications.messages",
                true,
            )
            "pairing_request" -> preferences.getBoolean(
                "flutter.torchat.notifications.pairing",
                true,
            )
            else -> true
        }
    }
}
