package org.torchat.core

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import org.json.JSONObject
import org.torchat.data.RuntimeJsonDispatcher
import org.torchat.runtime.RuntimeJsonHandle

private interface ClientRuntimeLibrary : Library {
    fun torchat_client_runtime_last_error(): Pointer?
    fun torchat_client_runtime_free_string(value: Pointer?)
    fun torchat_client_runtime_new(
        installationId: ByteArray,
        installationIdLen: Long,
        publicKey: ByteArray,
        publicKeyLen: Long,
        fingerprint: ByteArray,
        fingerprintLen: Long,
        nickname: ByteArray,
        nicknameLen: Long,
    ): Pointer?
    fun torchat_client_runtime_free(value: Pointer?)
    fun torchat_client_runtime_dispatch_json(value: Pointer?, request: ByteArray, requestLen: Long): Pointer?
    fun torchat_client_runtime_drain_events_json(value: Pointer?): Pointer?
    fun torchat_client_runtime_import_state_json(value: Pointer?, state: ByteArray, stateLen: Long): Pointer?
    fun torchat_client_runtime_export_state_json(value: Pointer?): Pointer?
}

private object ClientRuntimeNative {
    val api: ClientRuntimeLibrary = Native.load("torchat_client_runtime", ClientRuntimeLibrary::class.java)

    fun error(): String = api.torchat_client_runtime_last_error()?.let { pointer ->
        val value = pointer.getString(0)
        api.torchat_client_runtime_free_string(pointer)
        value
    } ?: "Rust client runtime operation failed"

    fun string(pointer: Pointer?): String {
        val valuePointer = pointer ?: error(error())
        val value = valuePointer.getString(0)
        api.torchat_client_runtime_free_string(valuePointer)
        return value
    }
}

class NativeClientRuntime private constructor(private var handle: Pointer?) : RuntimeJsonHandle {
    fun dispatch(method: String, params: JSONObject = JSONObject(), id: String? = null): String =
        dispatchJson(clientRuntimeRequestJson(method = method, params = params, id = id))

    fun dispatchJson(requestJson: String): String {
        val runtime = requireHandle()
        val request = requestJson.toByteArray(Charsets.UTF_8)
        return ClientRuntimeNative.string(
            ClientRuntimeNative.api.torchat_client_runtime_dispatch_json(
                runtime,
                request,
                request.size.toLong(),
            ),
        )
    }

    fun drainEventsJson(): String = ClientRuntimeNative.string(
        ClientRuntimeNative.api.torchat_client_runtime_drain_events_json(requireHandle()),
    )

    fun importStateJson(stateJson: String): String {
        val state = stateJson.toByteArray(Charsets.UTF_8)
        return ClientRuntimeNative.string(
            ClientRuntimeNative.api.torchat_client_runtime_import_state_json(
                requireHandle(),
                state,
                state.size.toLong(),
            ),
        )
    }

    fun exportStateJson(): String = ClientRuntimeNative.string(
        ClientRuntimeNative.api.torchat_client_runtime_export_state_json(requireHandle()),
    )

    private fun requireHandle(): Pointer = handle ?: error("Native client runtime is closed")

    override fun close() {
        val current = handle ?: return
        handle = null
        ClientRuntimeNative.api.torchat_client_runtime_free(current)
    }

    override fun importState(state: JSONObject) {
        importStateJson(state.toString())
    }

    override fun exportState(): JSONObject = JSONObject(exportStateJson())

    override fun dispatch(request: JSONObject): JSONObject = JSONObject(dispatchJson(request.toString()))

    override fun drainEvents(): org.json.JSONArray = org.json.JSONArray(drainEventsJson())

    private fun requireOpen() {
        requireHandle()
    }

    fun ensureOpen() {
        requireOpen()
    }

    companion object {
        fun create(
            installationId: String,
            publicKey: String,
            fingerprint: String,
            nickname: String,
        ): NativeClientRuntime {
            val installationIdBytes = installationId.toByteArray(Charsets.UTF_8)
            val publicKeyBytes = publicKey.toByteArray(Charsets.UTF_8)
            val fingerprintBytes = fingerprint.toByteArray(Charsets.UTF_8)
            val nicknameBytes = nickname.toByteArray(Charsets.UTF_8)
            return NativeClientRuntime(
                ClientRuntimeNative.api.torchat_client_runtime_new(
                    installationIdBytes,
                    installationIdBytes.size.toLong(),
                    publicKeyBytes,
                    publicKeyBytes.size.toLong(),
                    fingerprintBytes,
                    fingerprintBytes.size.toLong(),
                    nicknameBytes,
                    nicknameBytes.size.toLong(),
                ) ?: error(ClientRuntimeNative.error()),
            )
        }
    }
}

class NativeRuntimeJsonDispatcher(private val runtime: NativeClientRuntime) : RuntimeJsonDispatcher {
    override fun importStateJson(stateJson: String): String = runtime.importStateJson(stateJson)
    override fun dispatchJson(requestJson: String): String = runtime.dispatchJson(requestJson)
    override fun exportStateJson(): String = runtime.exportStateJson()
    override fun drainEventsJson(): String = runtime.drainEventsJson()
}

fun clientRuntimeRequestJson(method: String, params: JSONObject = JSONObject(), id: String? = null): String {
    val request = JSONObject()
    if (id != null) {
        request.put("id", id)
    }
    request.put("method", method)
    request.put("params", params)
    return request.toString()
}
