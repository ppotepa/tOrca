package org.torchat.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class StateMappersTest {
    @Test
    fun `parses canonical contact source values strictly`() {
        assertEquals(ContactSource.INVITE, " invite ".toContactSource())
        assertThrows(IllegalArgumentException::class.java) { "unknown".toContactSource() }
    }

    @Test
    fun `parses canonical conversation state values strictly`() {
        assertEquals(ConversationState.ACTIVE, " active ".toConversationState())
        assertThrows(IllegalArgumentException::class.java) { "NEW".toConversationState() }
        assertThrows(IllegalArgumentException::class.java) { "unknown".toConversationState() }
    }

    @Test
    fun `parses canonical message state values strictly`() {
        assertEquals(MessageState.QUEUED, "queued".toMessageState())
        assertEquals(MessageState.SENDING, "sending".toMessageState())
        assertThrows(IllegalArgumentException::class.java) { "pending".toMessageState() }
        assertThrows(IllegalArgumentException::class.java) { "received".toMessageState() }
        assertThrows(IllegalArgumentException::class.java) { "unknown".toMessageState() }
    }

    @Test
    fun `parses canonical pairing state values strictly`() {
        assertEquals(PairingState.PENDING, " pending ".toPairingState())
        assertEquals(PairingState.ACCEPTED, "accepted".toPairingState())
        assertThrows(IllegalArgumentException::class.java) { "unknown".toPairingState() }
    }

    @Test
    fun `legacy storage parsers canonicalize known old values`() {
        assertEquals(ConversationState.PENDING, "NEW".toLegacyConversationState())
        assertEquals(MessageState.QUEUED, "pending".toLegacyMessageState())
        assertEquals(MessageState.DELIVERED, " received ".toLegacyMessageState())
        assertEquals(PairingState.CANCELLED, "CANCELED".toLegacyPairingState())
    }
}
