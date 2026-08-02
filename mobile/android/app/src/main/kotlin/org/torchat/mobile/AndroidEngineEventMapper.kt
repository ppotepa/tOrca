package org.torchat.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.torchat.generated.EngineContract
import org.torchat.generated.GeneratedEngineEvent

fun mapEngineEventToPublishedEvents(engineEvent: JSONObject): List<Map<String, Any?>> {
    val event = GeneratedEngineEvent.fromJson(engineEvent)
    return when (event.type) {
        EngineContract.EVENT_RUNTIME -> listOf(event.objectValue(EngineContract.EVENT).toRuntimeMap())
        EngineContract.EVENT_CONNECTION -> listOf(mapRelayConnectionEvent(event).toRuntimeMap())
        EngineContract.EVENT_FATAL -> listOf(mapFatalEvent(event))
        EngineContract.EVENT_LOG -> listOf(mapLogEvent(event))
        else -> emptyList()
    }
}

private fun mapFatalEvent(event: GeneratedEngineEvent): Map<String, Any?> {
    val error = event.objectValue(EngineContract.ERROR)
    return mapOf(
        EngineContract.TYPE to EngineContract.RUNTIME_ERROR,
        EngineContract.MESSAGE to error
            .optString(EngineContract.MESSAGE)
            .ifBlank { "Client engine failed" },
    )
}

private fun mapLogEvent(event: GeneratedEngineEvent): Map<String, Any?> {
    val log = event.objectValue(EngineContract.LOG)
    return mapOf(
        EngineContract.TYPE to EngineContract.RUNTIME_LOG,
        EngineContract.MESSAGE to log.optString(EngineContract.MESSAGE),
    )
}

/** Relay connection is not Tor bootstrap. Keep it in the canonical transport
 * component stream so it cannot overwrite the platform-owned Tor status. */
private fun mapRelayConnectionEvent(event: GeneratedEngineEvent): JSONObject {
    val snapshot = event.objectValue(EngineContract.SNAPSHOT)
    val stateValue = snapshot.opt(EngineContract.STATE)
    val (state, retryAttempt, retryInMs) = when (stateValue) {
        is JSONObject -> {
            val backoff = stateValue.optJSONObject(EngineContract.BACKOFF)
            if (backoff == null) {
                Triple(EngineContract.CONNECTION_STATE_DISCONNECTED, 0, null)
            } else {
                Triple(
                    EngineContract.CONNECTION_STATE_BACKOFF,
                    backoff.optInt(EngineContract.ATTEMPT, 0),
                    backoff.optLong(EngineContract.RETRY_IN_MS).takeIf { it > 0 },
                )
            }
        }
        else -> Triple(
            snapshot.optString(EngineContract.STATE)
                .ifBlank { EngineContract.CONNECTION_STATE_DISCONNECTED },
            0,
            null,
        )
    }
    val detail = snapshot.optString(EngineContract.DETAIL)
    val label = relayStatusLabel(state, detail)
    return JSONObject()
        .put(EngineContract.TYPE, EngineContract.TRANSPORT_STATUS_CHANGED)
        .put("component", "relay")
        .put("state", connectionProbeState(state))
        .put(EngineContract.DETAIL, label)
        .put(EngineContract.RETRY_ATTEMPT, retryAttempt)
        .put(EngineContract.GENERATION, snapshot.optLong(EngineContract.GENERATION))
        .apply {
            retryInMs?.let { put(EngineContract.RETRY_IN_MS, it) }
        }
}

/** Keep engine diagnostics out of the user-facing transport status. The
 * connection state is canonical; `detail` only explains what triggered the
 * latest snapshot and frequently contains values such as `platform fact
 * applied` even when the relay is already connected. */
private fun relayStatusLabel(state: String, detail: String): String {
    val trimmed = detail.trim()
    val technicalDetail = trimmed.isEmpty() || trimmed in setOf(
        "engine actor initialized",
        "connect requested",
        "platform fact applied",
        "relay connected",
    )
    if (!technicalDetail) return trimmed

    return when (state) {
        EngineContract.CONNECTION_STATE_WAITING_FOR_TOR -> "Oczekiwanie na Tor"
        EngineContract.CONNECTION_STATE_CONNECTING -> "Łączenie z relay"
        EngineContract.CONNECTION_STATE_AUTHENTICATING -> "Uwierzytelnianie relay"
        EngineContract.CONNECTION_STATE_WAITING_FOR_READY -> "Oczekiwanie na gotowość relay"
        EngineContract.CONNECTION_STATE_CONNECTED -> "Relay połączony"
        EngineContract.CONNECTION_STATE_BACKOFF -> "Ponawianie połączenia relay"
        EngineContract.CONNECTION_STATE_STOPPED -> "Relay zatrzymany"
        else -> "Relay rozłączony"
    }
}

private fun connectionProbeState(state: String): String = when (state) {
    EngineContract.CONNECTION_STATE_WAITING_FOR_TOR -> EngineContract.TRANSPORT_PHASE_STARTING
    EngineContract.CONNECTION_STATE_DISCONNECTED,
    EngineContract.CONNECTION_STATE_STOPPED -> EngineContract.TRANSPORT_PHASE_OFFLINE
    EngineContract.CONNECTION_STATE_CONNECTING,
    EngineContract.CONNECTION_STATE_AUTHENTICATING,
    EngineContract.CONNECTION_STATE_WAITING_FOR_READY -> EngineContract.TRANSPORT_PHASE_CONNECTING
    EngineContract.CONNECTION_STATE_CONNECTED -> EngineContract.TRANSPORT_PHASE_CONNECTED
    EngineContract.CONNECTION_STATE_BACKOFF -> EngineContract.TRANSPORT_PHASE_RECONNECTING
    else -> EngineContract.TRANSPORT_PHASE_ERROR
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
