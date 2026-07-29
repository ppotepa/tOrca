package org.torchat.core

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer

private interface ClientEngineLibrary : Library {
    fun torchat_client_engine_last_error(): Pointer?
    fun torchat_client_engine_free_string(value: Pointer?)
    fun torchat_client_engine_new(configJson: ByteArray, configLen: Long): Pointer?
    fun torchat_client_engine_start(value: Pointer?): Int
    fun torchat_client_engine_submit_json(value: Pointer?, requestJson: ByteArray, requestLen: Long): Int
    fun torchat_client_engine_poll_json(value: Pointer?, timeoutMs: Long): Pointer?
    fun torchat_client_engine_platform_fact_json(value: Pointer?, factJson: ByteArray, factLen: Long): Int
    fun torchat_client_engine_shutdown(value: Pointer?)
    fun torchat_client_engine_free(value: Pointer?)
}

private object ClientEngineNative {
    val api: ClientEngineLibrary = Native.load("torchat_client_engine", ClientEngineLibrary::class.java)

    fun error(): String = api.torchat_client_engine_last_error()?.let { pointer ->
        val value = pointer.getString(0)
        api.torchat_client_engine_free_string(pointer)
        value
    } ?: "Rust client engine operation failed"

    fun string(pointer: Pointer?): String {
        val valuePointer = pointer ?: error(error())
        val value = valuePointer.getString(0)
        api.torchat_client_engine_free_string(valuePointer)
        return value
    }
}

class NativeClientEngine private constructor(private var handle: Pointer?) : AutoCloseable {
    fun start() {
        requireStatus(
            ClientEngineNative.api.torchat_client_engine_start(requireHandle()),
            "start client engine",
        )
    }

    fun submitJson(requestJson: String) {
        val request = requestJson.toByteArray(Charsets.UTF_8)
        requireStatus(
            ClientEngineNative.api.torchat_client_engine_submit_json(
                requireHandle(),
                request,
                request.size.toLong(),
            ),
            "submit engine request",
        )
    }

    fun pollJson(timeoutMs: Long): String {
        require(timeoutMs >= 0) { "timeoutMs must be non-negative" }
        return ClientEngineNative.string(
            ClientEngineNative.api.torchat_client_engine_poll_json(requireHandle(), timeoutMs),
        )
    }

    fun platformFactJson(factJson: String) {
        val fact = factJson.toByteArray(Charsets.UTF_8)
        requireStatus(
            ClientEngineNative.api.torchat_client_engine_platform_fact_json(
                requireHandle(),
                fact,
                fact.size.toLong(),
            ),
            "submit platform fact",
        )
    }

    fun shutdown() {
        val current = handle ?: return
        ClientEngineNative.api.torchat_client_engine_shutdown(current)
    }

    override fun close() {
        val current = handle ?: return
        handle = null
        ClientEngineNative.api.torchat_client_engine_shutdown(current)
        ClientEngineNative.api.torchat_client_engine_free(current)
    }

    private fun requireHandle(): Pointer = handle ?: error("Native client engine is closed")

    private fun requireStatus(status: Int, action: String) {
        check(status == 0) {
            ClientEngineNative.error().ifBlank { "Failed to $action" }
        }
    }

    companion object {
        fun create(configJson: String): NativeClientEngine {
            val config = configJson.toByteArray(Charsets.UTF_8)
            return NativeClientEngine(
                ClientEngineNative.api.torchat_client_engine_new(
                    config,
                    config.size.toLong(),
                ) ?: error(ClientEngineNative.error()),
            )
        }
    }
}
