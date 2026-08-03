package org.torchat.mobile

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.torchat.core.NativeClientEngine
import org.torchat.core.MlsEpochGetCallback
import org.torchat.core.MlsEpochSetCallback
import org.torchat.generated.EngineContract
import org.torchat.generated.GeneratedEngineEvent
import org.torchat.generated.GeneratedEngineResponse
import org.torchat.security.LocalSecretStore
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class AndroidEngineHost private constructor(
    private val engine: NativeClientEngine,
    private val operationJournalFile: File,
) : AutoCloseable {
    private val pendingResponses = ConcurrentHashMap<String, CompletableDeferred<JSONObject>>()

    fun start() {
        engine.start()
    }

    fun submitJson(requestJson: String) {
        engine.submitJson(requestJson)
    }

    fun submitCommand(requestId: String, command: JSONObject, commandId: String = stableCommandId(command)) {
        submitJson(
            JSONObject()
                .put(EngineContract.REQUEST_ID, requestId)
                .put(EngineContract.COMMAND_ID, commandId)
                .put(EngineContract.COMMAND, command)
                .toString(),
        )
    }

    @Synchronized
    private fun stableCommandId(command: JSONObject): String {
        val type = command.optString(EngineContract.TYPE).ifBlank { "unknown" }
        val targetKeys = when (type) {
            EngineContract.COMMAND_SEND_MESSAGE -> listOf(EngineContract.ARG_ID)
            EngineContract.COMMAND_RETRY_MESSAGE,
            EngineContract.COMMAND_DELETE_MESSAGE_LOCAL -> listOf(EngineContract.MESSAGE_ID)
            EngineContract.COMMAND_ACCEPT_PAIRING,
            EngineContract.COMMAND_REJECT_PAIRING,
            EngineContract.COMMAND_ARCHIVE_PAIRING,
            EngineContract.COMMAND_CANCEL_PAIRING -> listOf(EngineContract.COMMAND_PAIRING_ID)
            EngineContract.COMMAND_REQUEST_RELATIONSHIP_REMOVAL,
            EngineContract.COMMAND_VERIFY_CONTACT,
            EngineContract.COMMAND_UPDATE_CONTACT_SETTINGS,
            EngineContract.COMMAND_ROTATE_PEER_ENDPOINT,
            EngineContract.COMMAND_ROTATE_CONTACT_ENDPOINT_CAPABILITY,
            EngineContract.COMMAND_REVOKE_CONTACT_ENDPOINT_CAPABILITY ->
                listOf(EngineContract.COMMAND_INSTALLATION_ID)
            EngineContract.COMMAND_START_CONVERSATION -> listOf(EngineContract.COMMAND_CONTACT_ID)
            else -> emptyList()
        }
        val stableTarget = targetKeys.asSequence()
            .map { key -> command.optString(key) }
            .firstOrNull { it.isNotBlank() }
        if (stableTarget == null) return "command-${UUID.randomUUID()}"
        val key = "$type:$stableTarget"
        val retained = readOperationJournal().optString(key).takeIf { it.isNotBlank() }
        if (retained != null) return retained
        val id = "command-$type-$stableTarget"
        val journal = readOperationJournal()
        while (journal.length() >= MAX_OPERATION_JOURNAL_ENTRIES) {
            val keys = journal.keys()
            if (!keys.hasNext()) break
            journal.remove(keys.next())
        }
        journal.put(key, id)
        writeOperationJournal(journal)
        return id
    }

    private fun readOperationJournal(): JSONObject = try {
        if (!operationJournalFile.exists()) JSONObject()
        else JSONObject(operationJournalFile.readText(Charsets.UTF_8))
    } catch (_: Throwable) {
        JSONObject()
    }

    private fun writeOperationJournal(value: JSONObject) {
        val temporary = File(operationJournalFile.path + ".tmp")
        temporary.writeText(value.toString(), Charsets.UTF_8)
        Files.move(
            temporary.toPath(),
            operationJournalFile.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
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
        val commandType = command.optString(EngineContract.TYPE).ifBlank { "unknown" }
        val response = CompletableDeferred<JSONObject>()
        check(pendingResponses.putIfAbsent(requestId, response) == null) {
            "Duplicate engine request id: $requestId"
        }
        return try {
            Log.d("TorChat-Engine", "Submitting engine command type=$commandType requestId=$requestId")
            submitCommand(requestId, command)
            val decoded = GeneratedEngineResponse.fromJson(
                withTimeout(timeoutMs) { response.await() },
            )
            if (!decoded.ok) {
                error(decoded.errorMessage ?: decoded.errorCode ?: "Engine request failed")
            }
            Log.d("TorChat-Engine", "Engine command completed type=$commandType requestId=$requestId")
            decoded.value
        } catch (cancelled: CancellationException) {
            // Activity recreation routinely cancels an awaiting Flutter call.
            // The service-owned engine continues running, so this is neither
            // an engine failure nor an actionable error for the user.
            Log.d(
                "TorChat-Engine",
                "Engine command await cancelled type=$commandType requestId=$requestId",
            )
            throw cancelled
        } catch (error: Throwable) {
            Log.e(
                "TorChat-Engine",
                "Engine command failed type=$commandType requestId=$requestId timeoutMs=$timeoutMs",
                error,
            )
            throw error
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
        private const val MAX_OPERATION_JOURNAL_ENTRIES = 256

        fun create(config: Config): AndroidEngineHost = AndroidEngineHost(
            config.mlsEpochAnchorStore?.let { secrets ->
                val getEpoch = MlsEpochGetCallback { id, length, output ->
                    runCatching {
                        val conversationId = id.getByteArray(0, length.toInt())
                            .toString(Charsets.UTF_8)
                        val epoch = secrets.mlsEpochAnchor(conversationId)
                            ?: return@MlsEpochGetCallback 1
                        output.setLong(0, epoch)
                        0
                    }.getOrDefault(-1)
                }
                val setEpoch = MlsEpochSetCallback { id, length, epoch ->
                    runCatching {
                        val conversationId = id.getByteArray(0, length.toInt())
                            .toString(Charsets.UTF_8)
                        secrets.storeMlsEpochAnchor(conversationId, epoch)
                        0
                    }.getOrDefault(-1)
                }
                NativeClientEngine.createWithMlsEpochAnchor(
                    config.toJson().toString(),
                    getEpoch,
                    setEpoch,
                )
            } ?: NativeClientEngine.create(config.toJson().toString()),
            File(config.databasePath.parentFile, ".operation-command-ids.json"),
        )
    }

    data class Config(
        val databasePath: File,
        val databaseKey: ByteArray,
        val identityPrivateKey: ByteArray,
        val relayOnionUrl: String,
        val initialSocks5Url: String? = null,
        val logDirectory: File? = null,
        val mlsEpochAnchorStore: LocalSecretStore? = null,
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
