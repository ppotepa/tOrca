package org.torchat.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.torchat.generated.EngineContract

class AndroidEngineEventMapperTest {
    @Test
    fun connectedPlatformFactUsesCanonicalRelayLabel() {
        val event = connectionEvent(
            state = EngineContract.CONNECTION_STATE_CONNECTED,
            detail = "platform fact applied",
        )

        val published = mapEngineEventToPublishedEvents(event).single()

        assertEquals("READY", published["state"])
        assertEquals("Relay połączony", published[EngineContract.DETAIL])
    }

    @Test
    fun actionableTransportFailureRemainsVisible() {
        val detail = "relay transport error: connection refused"
        val event = connectionEvent(
            state = EngineContract.CONNECTION_STATE_BACKOFF,
            detail = detail,
        )

        val published = mapEngineEventToPublishedEvents(event).single()

        assertEquals("DEGRADED", published["state"])
        assertEquals(detail, published[EngineContract.DETAIL])
    }

    private fun connectionEvent(state: String, detail: String): JSONObject = JSONObject()
        .put(EngineContract.TYPE, EngineContract.EVENT_CONNECTION)
        .put(
            EngineContract.SNAPSHOT,
            JSONObject()
                .put(EngineContract.STATE, state)
                .put(EngineContract.DETAIL, detail)
                .put(EngineContract.GENERATION, 1L),
        )
}
