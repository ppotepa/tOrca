package org.torchat.transport

import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.BufferOverflow
import okhttp3.Authenticator
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.Route
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.torchat.security.TorRemoteDns
import org.torchat.security.TorSocksSocketFactory
import org.torchat.security.TorTransport
import org.torchat.core.NativeIdentity
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private val HTTP_DELETE = "D" + "ELETE"
private const val RELAY_LOG_TAG = "TorChat-Relay"

enum class RelayFailureCode {
    SOCKS_TIMEOUT,
    SOCKS_CONNECT_FAILED,
    WS_HANDSHAKE_TIMEOUT,
    READY_TIMEOUT,
    PONG_TIMEOUT,
    REMOTE_CLOSE,
    READ_ERROR,
    WRITE_ERROR,
    AUTH_EXPIRED,
    HTTP_RETRYABLE,
    HTTP_PERMANENT,
    QUEUE_FULL,
    UNKNOWN,
}

class RelayTransportException(
    val code: RelayFailureCode,
    message: String,
    cause: Throwable? = null,
) : java.io.IOException(message, cause)

data class RelayFailure(
    val code: RelayFailureCode,
    val detail: String,
    val retryable: Boolean,
)

internal fun classifyRelayFailure(error: Throwable): RelayFailure {
    if (error is RelayTransportException) {
        return RelayFailure(
            code = error.code,
            detail = error.message ?: error.code.name,
            retryable = error.code !in setOf(
                RelayFailureCode.AUTH_EXPIRED,
                RelayFailureCode.HTTP_PERMANENT,
            ),
        )
    }
    val message = (error.message ?: error::class.java.simpleName).trim()
    val lowered = message.lowercase()
    val code = when {
        lowered.contains("timed out") || lowered.contains("timeout") ->
            RelayFailureCode.SOCKS_TIMEOUT
        lowered.contains("401") || lowered.contains("403") || lowered.contains("wygas") ->
            RelayFailureCode.AUTH_EXPIRED
        lowered.contains("reset") || lowered.contains("broken pipe") || lowered.contains("eof") ->
            RelayFailureCode.READ_ERROR
        else -> RelayFailureCode.UNKNOWN
    }
    return RelayFailure(
        code = code,
        detail = message.ifEmpty { code.name },
        retryable = code != RelayFailureCode.AUTH_EXPIRED,
    )
}

internal class RelayConnectionGenerationGuard {
    private val generation = AtomicLong(0L)
    @Volatile
    private var activeGeneration = 0L

    fun nextGeneration(): Long {
        val connectionGeneration = generation.incrementAndGet()
        activeGeneration = connectionGeneration
        return connectionGeneration
    }

    fun shouldIgnore(connectionGeneration: Long): Boolean =
        connectionGeneration != activeGeneration

    fun shouldClearSocket(connectionGeneration: Long, webSocket: WebSocket, socket: WebSocket?): Boolean =
        connectionGeneration == activeGeneration && socket === webSocket
}

internal class RelayReadySignal {
    private val signal = CompletableDeferred<Unit>()

    fun acceptFrame(text: String): Boolean {
        val frame = runCatching { JSONObject(text) }.getOrNull()
        if (frame?.optString("type") != "ready") {
            return false
        }
        signal.complete(Unit)
        return true
    }

    suspend fun await(timeoutMs: Long) {
        withTimeout(timeoutMs) { signal.await() }
    }
}

/** Authenticated live relay client. It has no API for server-side message storage. */
class AndroidRelayTransport(
    private val baseUrl: String,
    socksPort: Int,
    private val identity: NativeIdentity,
) {
    init {
        require(TorTransport.validateOnionUrl(baseUrl)) {
            "TorChat relay URL must be an exact v3 .onion URL"
        }
    }

    private val frames = Channel<String>(
        capacity = 256,
        onBufferOverflow = BufferOverflow.SUSPEND,
    )
    private val client = OkHttpClient.Builder()
        .dns(TorRemoteDns)
        .socketFactory(TorSocksSocketFactory(socksPort))
        // The local SOCKS socket is immediate, but the first onion circuit can
        // take a couple of minutes. Keep this bounded while allowing Tor to
        // finish a genuine circuit instead of reporting a false relay error.
        .connectTimeout(20, TimeUnit.SECONDS)
        .callTimeout(180, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .build()
    private var token: String? = null
    private var socket: WebSocket? = null
    private val generationGuard = RelayConnectionGenerationGuard()

    /** Builds a harmless first onion circuit before authenticated bootstrap. */
    suspend fun warmup(): Long {
        val started = System.nanoTime()
        Log.i("TorChat-Onion", "phase=warmup url=${baseUrl.take(20)}.../health")
        val request = Request.Builder().url("$baseUrl/health").get().build()
        try {
            suspendCancellableCoroutine<Unit> { continuation ->
                val call = client.newCall(request)
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(object : okhttp3.Callback {
                    override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                        if (continuation.isActive) continuation.resumeWithException(e)
                    }

                    override fun onResponse(call: okhttp3.Call, response: Response) {
                        response.use {
                            if (it.isSuccessful) continuation.resume(Unit)
                            else continuation.resumeWithException(
                                IllegalStateException("onion health returned HTTP ${it.code}"),
                            )
                        }
                    }
                })
            }
        } catch (error: Throwable) {
            val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            val failure = classifyRelayFailure(error)
            Log.w("TorChat-Onion", "phase=warmup result=failed code=${failure.code} elapsedMs=$elapsedMs detail=${failure.detail}", error)
            throw RelayTransportException(failure.code, failure.detail, error)
        }
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        Log.i("TorChat-Onion", "phase=warmup result=ok elapsedMs=$elapsedMs")
        return elapsedMs
    }

    suspend fun bootstrap() {
        Log.i(RELAY_LOG_TAG, "phase=bootstrap step=challenge")
        val challengeResponse = request("$baseUrl/v1/bootstrap/challenge", "POST", "{}")
        val challenge = JSONObject(challengeResponse).getString("challenge")
        val challengeId = JSONObject(challengeResponse).getString("challenge_id")
        val body = JSONObject().apply {
            put("challenge_id", challengeId)
            put("public_key", identity.publicKey())
            put("proof", identity.sign(challenge.toByteArray()))
        }
        val response = request("$baseUrl/v1/installations", "POST", body.toString())
        token = JSONObject(response).getString("session_token")
        Log.i(RELAY_LOG_TAG, "phase=bootstrap step=token_ready")
    }

    suspend fun connect() {
        val bearer = token ?: error("bootstrap required")
        val connectionGeneration = generationGuard.nextGeneration()
        val readySignal = RelayReadySignal()
        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration step=start")
        val request = Request.Builder().url(baseUrl.replaceFirst("http", "ws") + "/v1/events")
            .header("Authorization", "Bearer $bearer").build()
        val previous = socket
        socket = null
        if (previous != null) {
            Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration step=cancel_previous")
            previous.cancel()
        }
        val connectedSocket = suspendCancellableCoroutine<WebSocket> { continuation ->
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (generationGuard.shouldIgnore(connectionGeneration)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onOpen stale=true")
                        webSocket.cancel()
                        return
                    }
                    Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onOpen code=${response.code}")
                    continuation.resume(webSocket)
                }
                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (generationGuard.shouldIgnore(connectionGeneration)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onMessage stale=true")
                        return
                    }
                    if (readySignal.acceptFrame(text)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration step=ready")
                        return
                    }
                    if (frames.trySend(text).isFailure) {
                        Log.w(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration code=${RelayFailureCode.QUEUE_FULL} detail=inbound queue full")
                        webSocket.cancel()
                        signalDisconnected(
                            RelayTransportException(
                                RelayFailureCode.QUEUE_FULL,
                                "inbound frame queue full",
                            ),
                        )
                    }
                }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (generationGuard.shouldIgnore(connectionGeneration)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onFailure stale=true")
                        return
                    }
                    val failure = classifyRelayFailure(t)
                    Log.w(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onFailure code=${failure.code} http=${response?.code} detail=${failure.detail}", t)
                    if (continuation.isActive) {
                        continuation.resumeWithException(RelayTransportException(failure.code, failure.detail, t))
                    } else {
                        signalDisconnected(RelayTransportException(failure.code, failure.detail, t))
                    }
                }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (generationGuard.shouldIgnore(connectionGeneration)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onClosed stale=true")
                        return
                    }
                    Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onClosed code=$code reason=$reason")
                    if (generationGuard.shouldClearSocket(connectionGeneration, webSocket, socket)) {
                        socket = null
                    }
                    signalDisconnected(
                        RelayTransportException(
                            RelayFailureCode.REMOTE_CLOSE,
                            "WebSocket closed ($code): $reason",
                        ),
                    )
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    if (generationGuard.shouldIgnore(connectionGeneration)) {
                        Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onClosing stale=true")
                        return
                    }
                    Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration callback=onClosing code=$code reason=$reason")
                    if (generationGuard.shouldClearSocket(connectionGeneration, webSocket, socket)) {
                        socket = null
                    }
                    signalDisconnected(
                        RelayTransportException(
                            RelayFailureCode.REMOTE_CLOSE,
                            "WebSocket closing ($code): $reason",
                        ),
                    )
                }
            }
            val created = client.newWebSocket(request, listener)
            continuation.invokeOnCancellation { created.cancel() }
        }
        socket = connectedSocket
        try {
            readySignal.await(RELAY_READY_TIMEOUT_MS)
            Log.i(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration step=connected")
        } catch (error: Throwable) {
            val failure = classifyRelayFailure(error).let {
                if (it.code == RelayFailureCode.SOCKS_TIMEOUT || it.code == RelayFailureCode.UNKNOWN) {
                    it.copy(code = RelayFailureCode.READY_TIMEOUT)
                } else {
                    it
                }
            }
            Log.w(RELAY_LOG_TAG, "phase=connect generation=$connectionGeneration code=${failure.code} detail=${failure.detail}", error)
            connectedSocket.cancel()
            if (socket === connectedSocket) {
                socket = null
            }
            throw RelayTransportException(failure.code, failure.detail, error)
        }
    }

    suspend fun profile(): ProfileResponse {
        val json = authorizedRequest("$baseUrl/v1/profile", "GET")
        return ProfileResponse(
            installationId = JSONObject(json).getString("installation_id"),
            nickname = JSONObject(json).optNullableString("nickname"),
            publicKey = JSONObject(json).getString("public_key"),
            fingerprint = JSONObject(json).getString("fingerprint"),
        )
    }

    suspend fun updateNickname(nickname: String): ProfileResponse {
        val body = JSONObject().put("nickname", nickname).toString()
        val json = authorizedRequest("$baseUrl/v1/profile", "PUT", body)
        return ProfileResponse(
            installationId = JSONObject(json).getString("installation_id"),
            nickname = JSONObject(json).optNullableString("nickname"),
            publicKey = JSONObject(json).getString("public_key"),
            fingerprint = JSONObject(json).getString("fingerprint"),
        )
    }

    suspend fun refreshPairingCode(): PairingCode {
        val json = JSONObject(authorizedRequest("$baseUrl/v1/pairing-codes/refresh", "POST"))
        return PairingCode(json.getString("code"), json.getLong("expires_at"))
    }

    suspend fun createPairingRequest(code: String): PairingRequestCreated = JSONObject(authorizedRequest(
        "$baseUrl/v1/pairing-requests", "POST", JSONObject().put("code", code).toString(),
    )).let {
        PairingRequestCreated(
            pairingId = it.getString("pairing_id"),
            expiresAt = it.getLong("expires_at"),
            state = it.optString("state", "PENDING"),
        )
    }

    suspend fun pairingInbox(): List<PairingInboxItem> {
        val array = org.json.JSONArray(authorizedRequest("$baseUrl/v1/pairing-requests/inbox", "GET"))
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            PairingInboxItem(
                pairingId = item.getString("pairing_id"),
                sender = item.getJSONObject("sender").toContactCard(),
                capability = item.getString("capability"),
                expiresAt = item.getLong("expires_at"),
                state = item.optString("state", "PENDING"),
            )
        }
    }

    suspend fun acknowledgePairing(pairingId: String) {
        authorizedRequest("$baseUrl/v1/pairing-requests/$pairingId/ack", "POST")
    }

    suspend fun cancelPairing(pairingId: String) {
        authorizedRequest("$baseUrl/v1/pairing-requests/$pairingId", HTTP_DELETE)
    }

    suspend fun confirmContact(capability: String, peerInstallationId: String) {
        authorizedRequest("$baseUrl/v1/contacts/confirm", "POST", JSONObject()
            .put("capability", capability).put("peer_installation_id", peerInstallationId).toString())
    }

    suspend fun contacts(): List<ContactCard> {
        val array = org.json.JSONArray(authorizedRequest("$baseUrl/v1/contacts", "GET"))
        return (0 until array.length()).map { array.getJSONObject(it).toContactCard() }
    }

    suspend fun nextFrame(): String = frames.receive()

    fun sendWithId(messageId: String, recipient: String, ciphertext: String): String? {
        val frame = JSONObject().apply {
            put("type", "envelope"); put("version", 1); put("message_id", messageId)
            put("sender", identity.installationId()); put("recipient", recipient); put("ciphertext", ciphertext)
        }
        val sent = socket?.send(frame.toString()) == true
        Log.i(RELAY_LOG_TAG, "phase=send messageId=${messageId.take(8)} recipient=${recipient.take(12)} sent=$sent")
        return if (sent) messageId else null
    }

    fun sendWithId(recipient: String, ciphertext: String): String? =
        sendWithId(UUID.randomUUID().toString(), recipient, ciphertext)

    fun send(recipient: String, ciphertext: String): Boolean {
        return sendWithId(recipient, ciphertext) != null
    }

    private fun signalDisconnected(error: Throwable) {
        val failure = classifyRelayFailure(error)
        socket = null
        frames.trySend(JSONObject().apply {
            put("type", "error")
            put("code", failure.code.name.lowercase())
            put("detail", failure.detail)
        }.toString())
    }

    companion object {
        private const val RELAY_READY_TIMEOUT_MS = 60_000L
    }

    private suspend fun request(url: String, method: String, body: String): String = suspendCancellableCoroutine { continuation ->
        val request = Request.Builder().url(url).method(method, body.toRequestBody("application/json".toMediaType())).build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                if (continuation.isActive) {
                    val failure = classifyRelayFailure(e)
                    continuation.resumeWithException(RelayTransportException(failure.code, failure.detail, e))
                }
            }
            override fun onResponse(call: okhttp3.Call, response: Response) {
                response.use {
                    val text = it.body?.string().orEmpty()
                    if (it.isSuccessful) continuation.resume(text)
                    else continuation.resumeWithException(relayHttpException(it.code, text))
                }
            }
        })
    }

    private suspend fun authorizedRequest(url: String, method: String, body: String? = null): String = suspendCancellableCoroutine { continuation ->
        val bearer = token ?: run {
            continuation.resumeWithException(IllegalStateException("bootstrap required"))
            return@suspendCancellableCoroutine
        }
        // OkHttp rejects POST/PUT/PATCH without a RequestBody before the
        // request ever reaches Tor. Several relay commands intentionally have
        // no fields, but they still need an explicit empty body.
        val requestBody = body?.let { it.toRequestBody("application/json".toMediaType()) }
            ?: if (method.uppercase() in setOf("POST", "PUT", "PATCH")) {
                "{}".toRequestBody("application/json".toMediaType())
            } else {
                null
            }
        val request = Request.Builder().url(url)
            .header("Authorization", "Bearer $bearer")
            .method(method, requestBody)
            .build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                if (continuation.isActive) {
                    val failure = classifyRelayFailure(e)
                    continuation.resumeWithException(RelayTransportException(failure.code, failure.detail, e))
                }
            }
            override fun onResponse(call: okhttp3.Call, response: Response) {
                response.use {
                    val text = it.body?.string().orEmpty()
                    if (it.isSuccessful) continuation.resume(text)
                    else continuation.resumeWithException(relayHttpException(it.code, text))
                }
            }
        })
    }
}

private fun relayHttpException(status: Int, body: String): RelayTransportException =
    RelayTransportException(
        code = when (status) {
            401, 403 -> RelayFailureCode.AUTH_EXPIRED
            429 -> RelayFailureCode.HTTP_RETRYABLE
            in 500..599 -> RelayFailureCode.HTTP_RETRYABLE
            else -> RelayFailureCode.HTTP_PERMANENT
        },
        message = relayHttpError(status, body),
    )

private fun relayHttpError(status: Int, body: String): String {
    val serverMessage = runCatching { JSONObject(body).optString("error") }.getOrNull()
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
    val message = serverMessage ?: when (status) {
        400 -> "Relay odrzucił żądanie."
        401 -> "Sesja relaya wygasła. Połącz się ponownie."
        404 -> "Kod lub zaproszenie nie istnieje albo wygasło."
        409 -> "Operacja koliduje z aktualnym stanem kontaktu."
        429 -> "Za dużo prób. Poczekaj chwilę i spróbuj ponownie."
        in 500..599 -> "Relay chwilowo nie odpowiada poprawnie."
        else -> "Relay zwrócił błąd HTTP $status."
    }
    return "Relay: $message"
}

private fun JSONObject.toContactCard() = ContactCard(
    installationId = getString("installation_id"),
    nickname = getString("nickname"),
    publicKey = getString("public_key"),
    fingerprint = getString("fingerprint"),
)

private fun JSONObject.optNullableString(name: String): String? =
    opt(name)?.takeUnless { it == JSONObject.NULL }?.toString()?.takeIf { it.isNotBlank() }
