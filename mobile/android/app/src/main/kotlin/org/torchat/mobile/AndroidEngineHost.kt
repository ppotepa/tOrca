package org.torchat.mobile

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.torchat.core.NativeClientEngine
import org.torchat.generated.EngineContract
import org.torchat.generated.GeneratedEngineEvent
import org.torchat.generated.GeneratedEngineResponse
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
                .put(EngineContract.REQUEST_ID, requestId)
                .put(EngineContract.COMMAND, command)
                .toString(),
        )
    }

    fun pollJson(timeoutMs: Long): String = engine.pollJson(timeoutMs)

    fun pollEvent(timeoutMs: Long): JSONObject? =
        pollJson(timeoutMs)
            .takeUnless { it == "null" }
            ?.let(::JSONObject)
            ?.also { GeneratedEngineEvent.fromJson(it) }

    fun acceptPolledEvent(event: JSONObject): Boolean {
        if (event.optString(EngineContract.TYPE) != EngineContract.EVENT_RESPONSE) {
            return false
        }
        val requestId = event.optString(EngineContract.REQUEST_ID).ifBlank { return false }
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
            val decoded = GeneratedEngineResponse.fromJson(
                withTimeout(timeoutMs) { response.await() },
            )
            if (!decoded.ok) {
                error(decoded.errorMessage ?: decoded.errorCode ?: "Engine request failed")
            }
            decoded.value
        } finally {
            pendingResponses.remove(requestId)
        }
    }

    suspend fun submitQueryAndAwait(type: String, timeoutMs: Long = 10_000L): Any? =
        submitCommandAndAwait(engineCommand(type), timeoutMs)

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
            .put(EngineContract.DATABASE_PATH, databasePath.absolutePath)
            .put(EngineContract.DATABASE_KEY, bytesJson(databaseKey))
            .put(EngineContract.IDENTITY_PRIVATE_KEY, bytesJson(identityPrivateKey))
            .put(EngineContract.RELAY_ONION_URL, relayOnionUrl)
            .put(EngineContract.INITIAL_SOCKS5_URL, initialSocks5Url ?: JSONObject.NULL)
            .put(EngineContract.LOG_DIRECTORY, logDirectory?.absolutePath ?: JSONObject.NULL)
            .put(EngineContract.PLATFORM, "android")
    }
}

fun engineCommand(type: String): JSONObject = JSONObject()
    .put(EngineContract.TYPE, type)

fun engineTorStatusFactJson(
    phase: String,
    progress: Int,
    detail: String,
): JSONObject = engineCommand(EngineContract.FACT_TOR_STATUS)
    .put(EngineContract.PHASE, phase)
    .put(EngineContract.PROGRESS, progress)
    .put(EngineContract.DETAIL, detail)

fun engineTorEndpointAvailableFactJson(socks5Url: String): JSONObject =
    engineCommand(EngineContract.FACT_TOR_ENDPOINT_AVAILABLE)
        .put(EngineContract.FACT_SOCKS5_URL, socks5Url)

fun engineTorEndpointLostFactJson(reason: String): JSONObject =
    engineCommand(EngineContract.FACT_TOR_ENDPOINT_LOST)
        .put(EngineContract.REASON, reason)

fun engineOnionServiceAvailableFactJson(
    onionAddress: String,
    virtualPort: Int,
    generation: Long,
): JSONObject = engineCommand(EngineContract.FACT_ONION_SERVICE_AVAILABLE)
    .put(EngineContract.FACT_ONION_ADDRESS, onionAddress)
    .put(EngineContract.FACT_VIRTUAL_PORT, virtualPort)
    .put(EngineContract.GENERATION, generation)

fun engineOnionServiceLostFactJson(reason: String): JSONObject =
    engineCommand(EngineContract.FACT_ONION_SERVICE_LOST)
        .put(EngineContract.REASON, reason)

fun engineAppVisibilityChangedFactJson(foreground: Boolean): JSONObject =
    engineCommand(EngineContract.FACT_APP_VISIBILITY_CHANGED)
        .put(EngineContract.FOREGROUND, foreground)

fun engineNetworkChangedFactJson(online: Boolean): JSONObject =
    engineCommand(EngineContract.FACT_NETWORK_CHANGED)
        .put(EngineContract.ONLINE, online)

fun enginePowerModeChangedFactJson(
    batterySaver: Boolean,
    deviceIdle: Boolean,
): JSONObject = engineCommand(EngineContract.FACT_POWER_MODE_CHANGED)
    .put(EngineContract.FACT_BATTERY_SAVER, batterySaver)
    .put(EngineContract.FACT_DEVICE_IDLE, deviceIdle)

fun engineBackgroundExecutionRestrictedFactJson(restricted: Boolean): JSONObject =
    engineCommand(EngineContract.FACT_BACKGROUND_EXECUTION_RESTRICTED)
        .put(EngineContract.RESTRICTED, restricted)

private fun bytesJson(value: ByteArray): JSONArray = JSONArray().apply {
    value.forEach { put(it.toInt() and 0xff) }
}
