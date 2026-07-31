package org.torchat.mobile

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

class AndroidEngineEventPump(
    private val host: AndroidEngineHost,
    private val scope: CoroutineScope,
    private val timeoutMs: Long = 250L,
    private val onEvent: (JSONObject) -> Unit,
    private val onFailure: (Throwable) -> Unit = {},
) {
    private val running = AtomicBoolean(false)
    private var job: Job? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        job = scope.launch(Dispatchers.IO) {
            while (isActive && running.get()) {
                runCatching { host.pollEvent(timeoutMs) }
                    .onSuccess { event ->
                        if (event != null && AndroidNotificationPolicy.shouldForward(event)) {
                            if (!host.acceptPolledEvent(event)) onEvent(event)
                        }
                    }
                    .onFailure { error ->
                        running.set(false)
                        onFailure(error)
                    }
            }
        }
    }

    suspend fun stop() {
        running.set(false)
        job?.cancelAndJoin()
        job = null
    }
}

internal fun shouldForwardEngineEvent(event: JSONObject): Boolean =
    AndroidNotificationPolicy.shouldForward(event)
