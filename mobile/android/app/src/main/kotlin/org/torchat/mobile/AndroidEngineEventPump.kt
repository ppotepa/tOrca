package org.torchat.mobile

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.torchat.generated.EngineContract
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
        if (!running.compareAndSet(false, true)) {
            return
        }
        job = scope.launch(Dispatchers.IO) {
            while (isActive && running.get()) {
                runCatching { host.pollEvent(timeoutMs) }
                    .onSuccess { event ->
                        if (event != null && shouldForwardEvent(event)) {
                            if (!host.acceptPolledEvent(event)) {
                                onEvent(event)
                            }
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

    internal fun shouldForwardEvent(event: JSONObject): Boolean {
        if (event.optString(EngineContract.TYPE) != EngineContract.EVENT_NOTIFICATION_REQUESTED) {
            return true
        }
        val notification = event.optJSONObject(EngineContract.NOTIFICATION) ?: return false
        val title = notification.optString(EngineContract.TITLE).trim()
        val body = notification.optString(EngineContract.BODY).trim()

        // The legacy actor emits this alert while processing PairingOffer,
        // which is already a post-acceptance protocol stage. It is not a new
        // inbox request and can be replayed after reconnect, producing stale
        // or duplicate user notifications. Pending invitations are rendered
        // from the committed pairing inbox instead.
        if (title == "Nowe zaproszenie" && body == "Masz nową prośbę o rozmowę.") {
            return false
        }
        return true
    }
}
