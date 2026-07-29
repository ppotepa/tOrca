package org.torchat.transport

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import java.lang.reflect.Proxy
import okhttp3.WebSocket

class RelayConnectionGenerationGuardTest {
    private fun socketProxy(): WebSocket =
        Proxy.newProxyInstance(
            WebSocket::class.java.classLoader,
            arrayOf(WebSocket::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "close" -> true
                "cancel" -> Unit
                "queueSize" -> 0L
                "request" -> null
                else -> null
            }
        } as WebSocket

    @Test
    fun stale_generation_cannot_clear_new_socket() {
        val guard = RelayConnectionGenerationGuard()
        val socket = socketProxy()

        val first = guard.nextGeneration()
        val second = guard.nextGeneration()

        assertTrue(guard.shouldIgnore(first))
        assertFalse(guard.shouldIgnore(second))
        assertFalse(guard.shouldClearSocket(first, socket, socket))
        assertTrue(guard.shouldClearSocket(second, socket, socket))
    }

    @Test
    fun ready_signal_requires_ready_frame() = runBlocking {
        val signal = RelayReadySignal()

        assertFalse(signal.acceptFrame("""{"type":"pong"}"""))
        val timedOut = runCatching { signal.await(10) }.exceptionOrNull()
        assertTrue(timedOut is TimeoutCancellationException)

        assertTrue(signal.acceptFrame("""{"type":"ready","installation_id":"alice"}"""))
        signal.await(10)
    }
}
