package org.torchat.mobile

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.torchat.core.NativeClientEngine
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class AndroidEngineHost private constructor(
    private val engine: NativeClientEngine,
) : AutoCloseable {
    private val pendingResponses = ConcurrentHashMap<String, CompletableDeferred<JSONObject>>()

    fun start() {
        engine.start()
    }

    fun submitJson(requestJson: String) {
        engine.submitJson(requestJson)
    }

    fun submitCommand(requestId: String, command: JSONObject) {
        submitJson(
            JSONObject()
                .put("requestId", requestId)
                .put("command", command)
                .toString(),
        )
    }

    fun pollJson(timeoutMs: Long): String = engine.pollJson(timeoutMs)

    fun pollEvent(timeoutMs: Long): JSONObject? =
        pollJson(timeoutMs)
            .takeUnless { it == "null" }
            ?.let(::JSONObject)

    fun acceptPolledEvent(event: JSONObject): Boolean {
        if (event.optString("type") != "response") {
            return false
        }
        val requestId = event.optString("requestId")
            .ifBlank { event.optString("request_id") }
            .ifBlank { return false }
        pendingResponses.remove(requestId)?.complete(event)
        return true
    }

    suspend fun submitCommandAndAwait(command: JSONObject, timeoutMs: Long = 10_000L): Any? {
        val requestId = UUID.randomUUID().toString()
        val response = CompletableDeferred<JSONObject>()
        check(pendingResponses.putIfAbsent(requestId, response) == null) {
            "Duplicate engine request id: $requestId"
        }
        return try {
            submitCommand(requestId, command)
            decodeResponse(withTimeout(timeoutMs) { response.await() })
        } finally {
            pendingResponses.remove(requestId)
        }
    }

    suspend fun submitQueryAndAwait(type: String, timeoutMs: Long = 10_000L): Any? =
        submitCommandAndAwait(JSONObject().put("type", type), timeoutMs)

    fun platformFactJson(factJson: String) {
        engine.platformFactJson(factJson)
    }

    fun publishPlatformFact(fact: JSONObject) {
        platformFactJson(fact.toString())
    }

    fun shutdown() {
        engine.shutdown()
    }

    override fun close() {
        pendingResponses.forEach { (_, deferred) ->
            deferred.completeExceptionally(IllegalStateException("Client engine host closed"))
        }
        pendingResponses.clear()
        engine.close()
    }

    companion object {
        fun create(config: Config): AndroidEngineHost =
            AndroidEngineHost(NativeClientEngine.create(config.toJson().toString()))
    }

    data class Config(
        val databasePath: File,
        val databaseKey: ByteArray,
        val identityPrivateKey: ByteArray,
        val relayOnionUrl: String,
        val initialSocks5Url: String? = null,
        val logDirectory: File? = null,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("databasePath", databasePath.absolutePath)
            .put("databaseKey", bytesJson(databaseKey))
            .put("identityPrivateKey", bytesJson(identityPrivateKey))
            .put("relayOnionUrl", relayOnionUrl)
            .put("initialSocks5Url", initialSocks5Url ?: JSONObject.NULL)
            .put("logDirectory", logDirectory?.absolutePath ?: JSONObject.NULL)
            .put("platform", "android")
    }
}

private fun decodeResponse(response: JSONObject): Any? {
    val result = response.optJSONObject("result") ?: error("Engine response missing result envelope")
    return when (result.optString("status")) {
        "ok" -> decodeOkPayload(result.optJSONObject("payload"))
        "error" -> error(result.optString("message").ifBlank { "Engine request failed" })
        else -> error("Engine response has unknown status: ${result.optString("status")}")
    }
}

private fun decodeOkPayload(payload: JSONObject?): Any? {
    val body = payload ?: return null
    return when (body.optString("type")) {
        "empty" -> null
        "json" -> normalizeJsonValue(body.opt("value"))
        else -> normalizeJsonValue(body.opt("value"))
    }
}

private fun normalizeJsonValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> value.keys().asSequence().associateWith { key ->
        normalizeJsonValue(value.opt(key))
    }
    is JSONArray -> List(value.length()) { index ->
        normalizeJsonValue(value.opt(index))
    }
    else -> value
}

fun engineTorStatusFactJson(
    phase: String,
    progress: Int,
    detail: String,
): JSONObject = JSONObject()
    .put("type", "tor_status")
    .put("phase", phase)
    .put("progress", progress)
    .put("detail", detail)

fun engineTorEndpointAvailableFactJson(socks5Url: String): JSONObject = JSONObject()
    .put("type", "tor_endpoint_available")
    .put("socks5Url", socks5Url)

fun engineTorEndpointLostFactJson(reason: String): JSONObject = JSONObject()
    .put("type", "tor_endpoint_lost")
    .put("reason", reason)

fun engineAppVisibilityChangedFactJson(foreground: Boolean): JSONObject = JSONObject()
    .put("type", "app_visibility_changed")
    .put("foreground", foreground)

fun engineNetworkChangedFactJson(): JSONObject = JSONObject()
    .put("type", "network_changed")

private fun bytesJson(value: ByteArray): JSONArray = JSONArray().apply {
    value.forEach { put(it.toInt() and 0xff) }
}
