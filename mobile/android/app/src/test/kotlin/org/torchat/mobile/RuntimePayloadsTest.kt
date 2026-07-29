package org.torchat.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimePayloadsTest {
    @Test
    fun `runtime profile response helper preserves identity fields`() {
        val profile = runtimeProfileResponse(
            installationId = "installation-alice",
            publicKey = "public-key",
            fingerprint = "fingerprint",
            nickname = "Alice",
        )

        assertEquals("installation-alice", profile.installationId)
        assertEquals("Alice", profile.nickname)
        assertEquals("public-key", profile.publicKey)
        assertEquals("fingerprint", profile.fingerprint)
    }

    @Test
    fun `runtime map list helper returns empty list for null input`() {
        val result = (null as Iterable<Int>?).toRuntimeMapList { mapOf("value" to it) }
        assertEquals(emptyList<Map<String, Any?>>(), result)
    }

    @Test
    fun `runtime map list helper maps every item`() {
        val result = listOf(1, 2, 3).toRuntimeMapList { mapOf("value" to it) }
        assertEquals(
            listOf(
                mapOf("value" to 1),
                mapOf("value" to 2),
                mapOf("value" to 3),
            ),
            result,
        )
    }
}
