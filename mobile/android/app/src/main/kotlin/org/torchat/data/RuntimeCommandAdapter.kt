package org.torchat.data

import org.json.JSONObject
import org.torchat.core.clientRuntimeRequestJson
import org.torchat.transport.PairingCode

interface RuntimeJsonDispatcher {
    fun importStateJson(stateJson: String): String
    fun dispatchJson(requestJson: String): String
    fun exportStateJson(): String
    fun drainEventsJson(): String
}

data class RuntimeCommandResult(
    val response: JSONObject,
    val events: List<Map<String, Any?>>,
) {
    fun resultArrayAsMaps(): List<Map<String, Any?>> {
        val result = response.optJSONArray("result") ?: return emptyList()
        return result.toMapList()
    }

    fun resultItemsAsMaps(): List<Map<String, Any?>> {
        val result = response.optJSONObject("result") ?: return emptyList()
        return result.optJSONArray("items")?.toMapList().orEmpty()
    }
}

fun MessageStore.applyRuntimeCommand(
    dispatcher: RuntimeJsonDispatcher,
    identity: RuntimeStateIdentity,
    nickname: String,
    method: String,
    params: JSONObject = JSONObject(),
    pairingCode: PairingCode? = null,
): RuntimeCommandResult {
    dispatcher.importStateJson(
        toRuntimeStateSnapshotJson(
            identity = identity,
            nickname = nickname,
            pairingCode = pairingCode,
        ),
    )
    val response = JSONObject(dispatcher.dispatchJson(clientRuntimeRequestJson(method = method, params = params)))
    check(response.optBoolean("ok")) {
        response.optString("error").ifBlank { "runtime command failed: $method" }
    }
    applyRuntimeStateSnapshotJson(dispatcher.exportStateJson())
    return RuntimeCommandResult(response, runtimeEventsFromJson(dispatcher.drainEventsJson()))
}

fun MessageStore.runtimeStateSnapshot(
    identity: RuntimeStateIdentity,
    nickname: String,
    pairingCode: PairingCode? = null,
): JSONObject = JSONObject(
    toRuntimeStateSnapshotJson(
        identity = identity,
        nickname = nickname,
        pairingCode = pairingCode,
    ),
)

fun MessageStore.applyRuntimeState(state: JSONObject) = applyRuntimeStateSnapshotJson(state.toString())

private fun runtimeEventsFromJson(eventsJson: String): List<Map<String, Any?>> {
    val events = org.json.JSONArray(eventsJson)
    return events.toMapList()
}

fun JSONObject.toRuntimeMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toRuntimeMap()
        is org.json.JSONArray -> value.toRuntimeList()
        else -> value
    }
}

fun org.json.JSONArray.toRuntimeList(): List<Any?> = List(length()) { index ->
    when (val value = get(index)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toRuntimeMap()
        is org.json.JSONArray -> value.toRuntimeList()
        else -> value
    }
}

fun org.json.JSONArray.toMapList(): List<Map<String, Any?>> = List(length()) { index ->
    getJSONObject(index).toRuntimeMap()
}
