package org.torchat.mobile

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.torchat.generated.EngineContract

/**
 * Starts the shared Rust relay state machine once.
 *
 * Retry, backoff, network recovery and connection generations belong to the
 * shared engine. Android only owns process lifecycle and publishes platform
 * facts. Keeping a second reconnect loop here caused duplicate CONNECT calls,
 * state oscillation and avoidable background wakeups.
 */
internal class RelaySupervisor(
    private val scope: CoroutineScope,
    private val startupLogger: StartupPlatformLogger,
    private val onState: (state: String, attempt: Int, detail: String) -> Unit,
) {
    @Volatile private var job: Job? = null
    @Volatile private var host: AndroidEngineHost? = null

    fun start(engineHost: AndroidEngineHost) {
        host = engineHost
        if (job?.isActive == true) return
        job = scope.launch {
            onState("connecting", 1, "Uruchamianie współdzielonego nadzorcy relay")
            val startedAt = System.currentTimeMillis()
            runCatching {
                withTimeout(60_000L) {
                    engineHost.submitCommandAndAwait(
                        engineCommand(EngineContract.COMMAND_CONNECT),
                        timeoutMs = 60_000L,
                    )
                }
            }.onSuccess {
                startupLogger.write(
                    level = "info",
                    component = "relay",
                    eventCode = "relay_supervisor_started",
                    stage = "RELAY_READY",
                    message = "Shared Rust relay supervisor accepted startup",
                    attempt = 1,
                    state = "ready",
                    durationMs = System.currentTimeMillis() - startedAt,
                )
                onState("ready", 1, "Nadzorca relay działa w engine")
            }.onFailure { error ->
                // A failed startup command is reported, but it is not retried
                // here. The shared actor owns its retry schedule.
                Log.w("TorChat-Engine", "Initial relay startup command failed", error)
                startupLogger.write(
                    level = "warn",
                    component = "relay",
                    eventCode = "relay_supervisor_start_deferred",
                    stage = "RELAY_READY",
                    message = error.message ?: "Relay startup deferred",
                    attempt = 1,
                    state = "retrying",
                    durationMs = System.currentTimeMillis() - startedAt,
                    errorCode = error.javaClass.simpleName,
                )
                onState("retrying", 1, error.message ?: "Engine ponowi relay w tle")
            }
        }
    }

    /** Network changes are published directly to the Rust engine by the service. */
    fun signalNetworkAvailable() = Unit

    fun stop() {
        job?.cancel()
        job = null
        host = null
    }
}
