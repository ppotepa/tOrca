package org.torchat.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class NativeClientRuntimeTest {
    @Test
    fun `request helper emits canonical runtime envelope`() {
        val json = clientRuntimeRequestJson(
            method = "sendMessage",
            params = JSONObject()
                .put("id", "conversation-1")
                .put("text", "hello"),
            id = "request-1",
        )

        val request = JSONObject(json)
        assertEquals("request-1", request.getString("id"))
        assertEquals("sendMessage", request.getString("method"))
        assertEquals("conversation-1", request.getJSONObject("params").getString("id"))
        assertEquals("hello", request.getJSONObject("params").getString("text"))
    }

    @Test
    fun `request helper omits absent id and keeps empty params object`() {
        val request = JSONObject(clientRuntimeRequestJson(method = "identity"))

        assertFalse(request.has("id"))
        assertEquals("identity", request.getString("method"))
        assertEquals(0, request.getJSONObject("params").length())
    }
}
