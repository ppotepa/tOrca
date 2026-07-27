package org.torchat.transport

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.channels.Channel
import okhttp3.Authenticator
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.Route
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONObject
import org.torchat.security.TorRemoteDns
import org.torchat.security.TorSocksSocketFactory
import org.torchat.security.TorTransport
import org.torchat.core.NativeIdentity
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

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

    private val frames = Channel<String>(Channel.UNLIMITED)
    private val client = OkHttpClient.Builder()
        .dns(TorRemoteDns)
        .socketFactory(TorSocksSocketFactory(socksPort))
        // Tor can accept the local socket shortly before it is ready to build
        // an onion circuit. Bound one attempt and let the foreground service
        // retry instead of leaving the splash on one request for 60–90s.
        .connectTimeout(20, TimeUnit.SECONDS)
        .callTimeout(35, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private var token: String? = null
    private var socket: WebSocket? = null

    suspend fun bootstrap() {
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
    }

    suspend fun connect() {
        val bearer = token ?: error("bootstrap required")
        val request = Request.Builder().url(baseUrl.replaceFirst("http", "ws") + "/v1/events")
            .header("Authorization", "Bearer $bearer").build()
        socket = suspendCancellableCoroutine { continuation ->
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { continuation.resume(webSocket) }
                override fun onMessage(webSocket: WebSocket, text: String) { frames.trySend(text) }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(t)
                    } else {
                        signalDisconnected(t.message ?: "WebSocket disconnected")
                    }
                }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    signalDisconnected("WebSocket closed ($code): $reason")
                }
            }
            val created = client.newWebSocket(request, listener)
            continuation.invokeOnCancellation { created.cancel() }
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

    suspend fun createPairingRequest(code: String): String = JSONObject(authorizedRequest(
        "$baseUrl/v1/pairing-requests", "POST", JSONObject().put("code", code).toString(),
    )).getString("pairing_id")

    suspend fun pairingInbox(): List<PairingInboxItem> {
        val array = org.json.JSONArray(authorizedRequest("$baseUrl/v1/pairing-requests/inbox", "GET"))
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            PairingInboxItem(
                pairingId = item.getString("pairing_id"),
                sender = item.getJSONObject("sender").toContactCard(),
                capability = item.getString("capability"),
                expiresAt = item.getLong("expires_at"),
            )
        }
    }

    suspend fun acknowledgePairing(pairingId: String) {
        authorizedRequest("$baseUrl/v1/pairing-requests/$pairingId/ack", "POST")
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
        return if (socket?.send(frame.toString()) == true) messageId else null
    }

    fun sendWithId(recipient: String, ciphertext: String): String? =
        sendWithId(UUID.randomUUID().toString(), recipient, ciphertext)

    fun send(recipient: String, ciphertext: String): Boolean {
        return sendWithId(recipient, ciphertext) != null
    }

    fun sendReceipt(messageId: String, sender: String): Boolean = socket?.send(JSONObject().apply {
        put("type", "delivery_receipt"); put("message_id", messageId); put("sender", sender)
    }.toString()) == true

    private fun signalDisconnected(reason: String) {
        socket = null
        frames.trySend(JSONObject().apply {
            put("type", "error")
            put("code", "transport_disconnected")
            put("detail", reason)
        }.toString())
    }

    private suspend fun request(url: String, method: String, body: String): String = suspendCancellableCoroutine { continuation ->
        val request = Request.Builder().url(url).method(method, okhttp3.RequestBody.create("application/json".toMediaType(), body)).build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) { if (continuation.isActive) continuation.resumeWithException(e) }
            override fun onResponse(call: okhttp3.Call, response: Response) {
                response.use {
                    val text = it.body?.string().orEmpty()
                    if (it.isSuccessful) continuation.resume(text) else continuation.resumeWithException(IllegalStateException("relay HTTP ${it.code}: $text"))
                }
            }
        })
    }

    private suspend fun authorizedRequest(url: String, method: String, body: String? = null): String = suspendCancellableCoroutine { continuation ->
        val bearer = token ?: run {
            continuation.resumeWithException(IllegalStateException("bootstrap required"))
            return@suspendCancellableCoroutine
        }
        val request = Request.Builder().url(url)
            .header("Authorization", "Bearer $bearer")
            .method(method, body?.let { okhttp3.RequestBody.create("application/json".toMediaType(), it) })
            .build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }
            override fun onResponse(call: okhttp3.Call, response: Response) {
                response.use {
                    val text = it.body?.string().orEmpty()
                    if (it.isSuccessful) continuation.resume(text)
                    else continuation.resumeWithException(IllegalStateException("relay HTTP ${it.code}: $text"))
                }
            }
        })
    }
}

private fun JSONObject.toContactCard() = ContactCard(
    installationId = getString("installation_id"),
    nickname = getString("nickname"),
    publicKey = getString("public_key"),
    fingerprint = getString("fingerprint"),
)

private fun JSONObject.optNullableString(name: String): String? =
    opt(name)?.takeUnless { it == JSONObject.NULL }?.toString()?.takeIf { it.isNotBlank() }
