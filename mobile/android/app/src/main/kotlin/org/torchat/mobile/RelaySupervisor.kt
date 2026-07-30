package org.torchat.mobile

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.torchat.generated.EngineContract
import kotlin.math.min
import kotlin.random.Random

internal class RelaySupervisor(
    private val scope: CoroutineScope,
    private val startupLogger: StartupPlatformLogger,
    private val onState: (state: String, attempt: Int, detail: String) -> Unit,
) {
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    @Volatile private var job: Job? = null
    @Volatile private var host: AndroidEngineHost? = null

    fun start(engineHost: AndroidEngineHost) {
        host = engineHost
        if (job?.isActive == true) {
            wakeups.trySend(Unit)
            return
        }
        job = scope.launch { runLoop() }
    }

    fun signalNetworkAvailable() {
        wakeups.trySend(Unit)
    }

    fun stop() {
        job?.cancel()
        job = null
        host = null
        wakeups.trySend(Unit)
    }

    private suspend fun runLoop() {
        var attempt = 0
        while (scope.isActive) {
            val currentHost = host
            if (currentHost == null) {
                wakeups.receive()
                continue
            }
            attempt += 1
            onState("connecting", attempt, "Łączenie z relayem")
            val startedAt = System.currentTimeMillis()
            val result = runCatching {
                withTimeout(60_000L) {
                    currentHost.submitCommandAndAwait(
                        engineCommand(EngineContract.COMMAND_CONNECT),
                        timeoutMs = 60_000L,
                    )
                }
            }
            if (result.isSuccess) {
                startupLogger.write(
                    level = "info",
                    component = "relay",
                    eventCode = "relay_connected",
                    stage = "RELAY_READY",
                    message = "Relay connection established",
                    attempt = attempt,
                    state = "ready",
                    durationMs = System.currentTimeMillis() - startedAt,
                )
                onState("ready", attempt, "Relay połączony")
                attempt = 0
                wakeups.receive()
                continue
            }

            val error = result.exceptionOrNull()
            val exponent = min(attempt - 1, 5)
            val baseDelay = min(1_000L shl exponent, 30_000L)
            val jitter = Random.nextLong(0L, min(1_000L, baseDelay / 3 + 1))
            val retryDelayMs = baseDelay + jitter
            Log.w(
                "TorChat-Engine",
                "Relay connect attempt $attempt failed; retrying in ${retryDelayMs}ms",
                error,
            )
            startupLogger.write(
                level = "warn",
                component = "relay",
                eventCode = "relay_connect_retry",
                stage = "RELAY_READY",
                message = error?.message ?: "Relay connection failed",
                attempt = attempt,
                state = "retrying",
                durationMs = System.currentTimeMillis() - startedAt,
                errorCode = error?.javaClass?.simpleName,
            )
            onState("retrying", attempt, error?.message ?: "Relay connection failed")
            delay(retryDelayMs)
        }
    }
}
