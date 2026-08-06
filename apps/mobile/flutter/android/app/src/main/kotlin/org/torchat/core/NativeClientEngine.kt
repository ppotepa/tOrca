package org.torchat.core

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.ptr.PointerByReference
import org.json.JSONObject

private const val REQUIRED_ENGINE_ABI_VERSION = 1
private const val FFI_OK = 0

private interface ClientEngineLibrary : Library {
    fun torca_engine_abi_version(): Int
    fun torca_engine_last_problem_json(): Pointer?
    fun torchat_client_engine_free_string(value: Pointer?)

    fun torca_engine_new_v1(
        configJson: ByteArray,
        configLen: Long,
        outHandle: PointerByReference,
    ): Int

    fun torca_engine_new_with_mls_epoch_anchor_v1(
        configJson: ByteArray,
        configLen: Long,
        getEpoch: MlsEpochGetCallback?,
        setEpoch: MlsEpochSetCallback?,
        outHandle: PointerByReference,
    ): Int

    fun torca_engine_start_v1(value: Pointer?): Int
    fun torca_engine_submit_json_v1(
        value: Pointer?,
        requestJson: ByteArray,
        requestLen: Long,
    ): Int

    fun torca_engine_poll_json_v1(
        value: Pointer?,
        timeoutMs: Long,
        outJson: PointerByReference,
    ): Int

    fun torca_engine_platform_fact_json_v1(
        value: Pointer?,
        factJson: ByteArray,
        factLen: Long,
    ): Int

    fun torca_engine_shutdown_v1(value: Pointer?): Int
    fun torca_engine_free_v1(value: PointerByReference): Int
}

fun interface MlsEpochGetCallback : Callback {
    fun invoke(conversationId: Pointer, conversationIdLen: Long, epochOut: Pointer): Int
}

fun interface MlsEpochSetCallback : Callback {
    fun invoke(conversationId: Pointer, conversationIdLen: Long, epoch: Long): Int
}

private object ClientEngineNative {
    val api: ClientEngineLibrary = Native.load(
        "torchat_client_engine",
        ClientEngineLibrary::class.java,
    )

    init {
        val actualVersion = api.torca_engine_abi_version()
        check(actualVersion == REQUIRED_ENGINE_ABI_VERSION) {
            "Unsupported client engine ABI: expected $REQUIRED_ENGINE_ABI_VERSION, found $actualVersion"
        }
    }

    fun problem(): String = api.torca_engine_last_problem_json()?.let { pointer ->
        val payload = pointer.getString(0)
        api.torchat_client_engine_free_string(pointer)
        runCatching {
            val problem = JSONObject(payload)
            val code = problem.optString("code").ifBlank { "internal" }
            val diagnostic = problem.optString("diagnosticContext")
            if (diagnostic.isBlank()) code else "$code: $diagnostic"
        }.getOrDefault(payload)
    } ?: "internal: Rust client engine operation failed"

    fun takeString(pointer: Pointer?): String {
        val valuePointer = pointer ?: error(problem())
        val value = valuePointer.getString(0)
        api.torchat_client_engine_free_string(valuePointer)
        return value
    }
}

class NativeClientEngine private constructor(
    private var handle: Pointer?,
    @Suppress("UNUSED_PARAMETER") private val getEpochCallback: MlsEpochGetCallback? = null,
    @Suppress("UNUSED_PARAMETER") private val setEpochCallback: MlsEpochSetCallback? = null,
) : AutoCloseable {
    fun start() {
        requireStatus(
            ClientEngineNative.api.torca_engine_start_v1(requireHandle()),
            "start client engine",
        )
    }

    fun submitJson(requestJson: String) {
        val request = requestJson.toByteArray(Charsets.UTF_8)
        requireStatus(
            ClientEngineNative.api.torca_engine_submit_json_v1(
                requireHandle(),
                request,
                request.size.toLong(),
            ),
            "submit engine request",
        )
    }

    fun pollJson(timeoutMs: Long): String {
        require(timeoutMs >= 0) { "timeoutMs must be non-negative" }
        val outJson = PointerByReference()
        requireStatus(
            ClientEngineNative.api.torca_engine_poll_json_v1(
                requireHandle(),
                timeoutMs,
                outJson,
            ),
            "poll engine event",
        )
        return ClientEngineNative.takeString(outJson.value)
    }

    fun platformFactJson(factJson: String) {
        val fact = factJson.toByteArray(Charsets.UTF_8)
        requireStatus(
            ClientEngineNative.api.torca_engine_platform_fact_json_v1(
                requireHandle(),
                fact,
                fact.size.toLong(),
            ),
            "submit platform fact",
        )
    }

    fun shutdown() {
        val current = handle ?: return
        requireStatus(
            ClientEngineNative.api.torca_engine_shutdown_v1(current),
            "shutdown client engine",
        )
    }

    override fun close() {
        val current = handle ?: return
        val reference = PointerByReference(current)
        runCatching { ClientEngineNative.api.torca_engine_shutdown_v1(current) }
        requireStatus(
            ClientEngineNative.api.torca_engine_free_v1(reference),
            "free client engine",
        )
        handle = reference.value
    }

    private fun requireHandle(): Pointer = handle ?: error("Native client engine is closed")

    private fun requireStatus(status: Int, action: String) {
        check(status == FFI_OK) {
            ClientEngineNative.problem().ifBlank { "Failed to $action" }
        }
    }

    companion object {
        fun create(configJson: String): NativeClientEngine {
            val config = configJson.toByteArray(Charsets.UTF_8)
            val outHandle = PointerByReference()
            val status = ClientEngineNative.api.torca_engine_new_v1(
                config,
                config.size.toLong(),
                outHandle,
            )
            check(status == FFI_OK) { ClientEngineNative.problem() }
            return NativeClientEngine(
                outHandle.value ?: error("Engine ABI returned a null handle"),
            )
        }

        fun createWithMlsEpochAnchor(
            configJson: String,
            getEpoch: MlsEpochGetCallback,
            setEpoch: MlsEpochSetCallback,
        ): NativeClientEngine {
            val config = configJson.toByteArray(Charsets.UTF_8)
            val outHandle = PointerByReference()
            val status = ClientEngineNative.api.torca_engine_new_with_mls_epoch_anchor_v1(
                config,
                config.size.toLong(),
                getEpoch,
                setEpoch,
                outHandle,
            )
            check(status == FFI_OK) { ClientEngineNative.problem() }
            return NativeClientEngine(
                outHandle.value ?: error("Engine ABI returned a null handle"),
                getEpoch,
                setEpoch,
            )
        }
    }
}
