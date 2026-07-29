package org.torchat.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.torchat.generated.EngineContract

private val runtimeEventTypes = setOf(
    EngineContract.RUNTIME_READY,
    EngineContract.TOR_STATUS,
    EngineContract.PROFILE_READY,
    EngineContract.INVITE_RECEIVED,
    EngineContract.INVITE_STATE_CHANGED,
    EngineContract.MESSAGE_RECEIVED,
    EngineContract.MESSAGE_STATE_CHANGED,
    EngineContract.CONVERSATION_READ_CHANGED,
    EngineContract.CHANGED,
    EngineContract.RUNTIME_ERROR,
    EngineContract.RUNTIME_LOG,
)

fun mapEngineEventToPublishedEvents(engineEvent: JSONObject): List<Map<String, Any?>> {
    val type = engineEvent.optString("type")
    return when {
        type in runtimeEventTypes -> listOf(engineEvent.toRuntimeMap())
        type == "runtime" -> mapRuntimeWrapper(engineEvent)
        type == "connection" -> listOf(mapConnectionEvent(engineEvent).toRuntimeMap())
        type == "fatal" -> listOf(
            mapOf(
                EngineContract.TYPE to EngineContract.RUNTIME_ERROR,
                "message" to engineEvent.optString("message").ifBlank { "Client engine failed" },
            ),
        )
        type == "log" -> listOf(
            mapOf(
                EngineContract.TYPE to EngineContract.RUNTIME_LOG,
                "message" to engineEvent.optString("message"),
            ),
        )
        else -> emptyList()
    }
}

private fun mapRuntimeWrapper(engineEvent: JSONObject): List<Map<String, Any?>> {
    val runtimeEvent = engineEvent.optJSONObject("runtime")
        ?: engineEvent.optJSONObject("event")
        ?: engineEvent.optJSONObject("value")
        ?: return emptyList()
    return listOf(runtimeEvent.toRuntimeMap())
}

private fun mapConnectionEvent(engineEvent: JSONObject): JSONObject {
    val snapshot = engineEvent.optJSONObject("connection") ?: engineEvent
    val stateValue = snapshot.opt("state")
    val (state, retryAttempt, retryInMs) = when (stateValue) {
        is JSONObject -> {
            val backoff = stateValue.optJSONObject("backoff")
            if (backoff != null) {
                Triple(
                    "backoff",
                    backoff.optInt("attempt", 0),
                    backoff.optLong("retryInMs"),
                )
            } else {
                Triple("disconnected", 0, null)
            }
        }
        else -> Triple(snapshot.optString("state").ifBlank { "disconnected" }, 0, null)
    }
    val detail = snapshot.optString("detail")
    return JSONObject()
        .put(EngineContract.TYPE, EngineContract.TOR_STATUS)
        .put("phase", connectionPhase(state))
        .put("label", detail.ifBlank { state.replace('_', ' ') })
        .put("detail", detail.ifBlank { state.replace('_', ' ') })
        .put("retryAttempt", retryAttempt)
        .put("generation", snapshot.optLong("generation"))
        .apply {
            if (retryInMs != null) {
                put("retryInMs", retryInMs)
            }
        }
}

private fun connectionPhase(state: String): String = when (state) {
    "waiting_for_tor" -> "starting"
    "disconnected" -> "offline"
    "connecting" -> "connecting"
    "authenticating" -> "connecting"
    "waiting_for_ready" -> "connecting"
    "connected" -> "connected"
    "backoff" -> "reconnecting"
    "stopped" -> "offline"
    else -> state
}

private fun JSONObject.toRuntimeMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toRuntimeMap()
        is JSONArray -> value.toRuntimeList()
        else -> value
    }
}

private fun JSONArray.toRuntimeList(): List<Any?> = List(length()) { index ->
    when (val value = get(index)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toRuntimeMap()
        is JSONArray -> value.toRuntimeList()
        else -> value
    }
}
