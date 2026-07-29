package org.torchat.chat

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class ApplicationPayloadTest {
    @Test
    fun message_payload_round_trips() {
        val payload = ApplicationPayload.Message(
            version = 1,
            messageId = UUID.fromString("00000000-0000-0000-0000-000000000021"),
            sentAt = 42,
            body = "hello",
        )

        val encoded = ApplicationPayload.encode(payload)
        assertEquals(payload, ApplicationPayload.decode(encoded))
    }

    @Test
    fun delivery_receipt_payload_round_trips() {
        val payload = ApplicationPayload.DeliveryReceipt(
            version = 1,
            messageId = UUID.fromString("00000000-0000-0000-0000-000000000022"),
            receivedAt = 43,
        )

        val encoded = ApplicationPayload.encode(payload)
        assertEquals(payload, ApplicationPayload.decode(encoded))
    }
}
