package org.torchat.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable

interface RuntimeJsonHandle : Closeable {
    fun importState(state: JSONObject)
    fun exportState(): JSONObject
    fun dispatch(request: JSONObject): JSONObject
    fun drainEvents(): JSONArray
}

data class RuntimeDispatchResult(
    val response: JSONObject,
    val exportedState: JSONObject,
    val events: List<JSONObject>,
)

class RuntimeSessionHost(
    private val runtime: RuntimeJsonHandle,
) : Closeable {
    private val lock = Any()
    private var initialized = false
    private var closed = false

    fun initialize(state: JSONObject) = synchronized(lock) {
        checkOpen()
        check(!initialized) { "runtime session is already initialized" }
        runtime.importState(state)
        initialized = true
    }

    fun importState(state: JSONObject) = synchronized(lock) {
        checkReady()
        runtime.importState(state)
    }

    fun dispatch(method: String, params: JSONObject = JSONObject()): RuntimeDispatchResult =
        synchronized(lock) {
            checkReady()
            val response = runtime.dispatch(
                JSONObject().put("method", method).put("params", params),
            )
            val events = runtime.drainEvents().toObjectList()
            val exportedState = runtime.exportState()
            RuntimeDispatchResult(response, exportedState, events)
        }

    fun drainEvents(): List<JSONObject> = synchronized(lock) {
        checkReady()
        runtime.drainEvents().toObjectList()
    }

    fun exportState(): JSONObject = synchronized(lock) {
        checkReady()
        runtime.exportState()
    }

    override fun close() = synchronized(lock) {
        if (closed) return
        closed = true
        runtime.close()
    }

    private fun checkOpen() {
        check(!closed) { "runtime session is closed" }
    }

    private fun checkReady() {
        checkOpen()
        check(initialized) { "runtime session is not initialized" }
    }
}

private fun JSONArray.toObjectList(): List<JSONObject> = List(length()) { index ->
    getJSONObject(index)
}
