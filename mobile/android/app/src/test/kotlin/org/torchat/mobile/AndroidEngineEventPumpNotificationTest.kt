package org.torchat.mobile

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.torchat.generated.EngineContract

class AndroidEngineEventPumpNotificationTest {
    @Test
    fun legacyPairingOfferNotificationIsSuppressed() {
        val event = JSONObject()
            .put(EngineContract.TYPE, EngineContract.EVENT_NOTIFICATION_REQUESTED)
            .put(
                EngineContract.NOTIFICATION,
                JSONObject()
                    .put(EngineContract.TITLE, "Nowe zaproszenie")
                    .put(EngineContract.BODY, "Masz nową prośbę o rozmowę."),
            )

        assertFalse(shouldForwardEngineEvent(event))
    }

    @Test
    fun ordinaryMessageNotificationIsForwarded() {
        val event = JSONObject()
            .put(EngineContract.TYPE, EngineContract.EVENT_NOTIFICATION_REQUESTED)
            .put(
                EngineContract.NOTIFICATION,
                JSONObject()
                    .put(EngineContract.TITLE, "Nowa wiadomość")
                    .put(EngineContract.BODY, "Cześć"),
            )

        assertTrue(shouldForwardEngineEvent(event))
    }

    @Test
    fun nonNotificationEventIsForwarded() {
        val event = JSONObject()
            .put(EngineContract.TYPE, EngineContract.TOR_STATUS)

        assertTrue(shouldForwardEngineEvent(event))
    }
}
