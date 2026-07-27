package org.torchat.chat

import android.util.Base64
import org.json.JSONObject
import org.torchat.core.NativeIdentity
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest

data class WelcomePayload(
    val senderInstallationId: String,
    val senderPublicKey: String,
    val senderFingerprint: String,
    val senderNickname: String,
    val recipient: String,
    val inviteId: String,
    val welcome: ByteArray,
    val ratchetTree: ByteArray,
    val signature: String,
)

sealed interface DecodedRelayPayload {
    data class PairingOffer(val pairingId: String, val capability: String, val invite: String) : DecodedRelayPayload
    data class PairingRejected(val pairingId: String) : DecodedRelayPayload
    data class Welcome(val value: WelcomePayload) : DecodedRelayPayload
    data class Application(val ciphertext: ByteArray) : DecodedRelayPayload
}

object RelayPayloads {
    private const val VERSION = 1

    fun pairingOffer(pairingId: String, capability: String, invite: String): String = encode(JSONObject().apply {
        put("kind", "pairing_offer")
        put("version", VERSION)
        put("pairing_id", pairingId)
        put("capability", capability)
        put("invite", invite)
    })

    fun pairingRejected(pairingId: String): String = encode(JSONObject().apply {
        put("kind", "pairing_rejected")
        put("version", VERSION)
        put("pairing_id", pairingId)
    })

    fun application(ciphertext: ByteArray): String = encode(JSONObject().apply {
        put("kind", "application")
        put("version", VERSION)
        put("ciphertext", b64(ciphertext))
    })

    fun welcome(
        identity: NativeIdentity,
        nickname: String,
        recipient: String,
        inviteId: String,
        welcome: ByteArray,
        ratchetTree: ByteArray,
    ): String {
        val sender = JSONObject().apply {
            put("installation_id", identity.installationId())
            put("public_key", identity.publicKey())
            put("fingerprint", identity.fingerprint())
            put("nickname", nickname)
        }
        val welcome64 = b64(welcome)
        val tree64 = b64(ratchetTree)
        val signature = identity.sign(signingBytes(
            sender.getString("installation_id"),
            sender.getString("public_key"),
            sender.getString("fingerprint"),
            sender.getString("nickname"),
            recipient,
            inviteId,
            welcome64,
            tree64,
        ))
        return encode(JSONObject().apply {
            put("kind", "welcome")
            put("version", VERSION)
            put("sender", sender)
            put("recipient", recipient)
            put("invite_id", inviteId)
            put("welcome", welcome64)
            put("ratchet_tree", tree64)
            put("signature", signature)
        })
    }

    fun decode(encoded: String): DecodedRelayPayload {
        val json = JSONObject(String(unb64(encoded), Charsets.UTF_8))
        require(json.getInt("version") == VERSION) { "unsupported relay payload version" }
        return when (json.getString("kind")) {
            "pairing_offer" -> DecodedRelayPayload.PairingOffer(
                json.getString("pairing_id"), json.getString("capability"), json.getString("invite"),
            )
            "pairing_rejected" -> DecodedRelayPayload.PairingRejected(json.getString("pairing_id"))
            "application" -> DecodedRelayPayload.Application(unb64(json.getString("ciphertext")))
            "welcome" -> {
                val sender = json.getJSONObject("sender")
                DecodedRelayPayload.Welcome(WelcomePayload(
                    senderInstallationId = sender.getString("installation_id"),
                    senderPublicKey = sender.getString("public_key"),
                    senderFingerprint = sender.getString("fingerprint"),
                    senderNickname = sender.getString("nickname"),
                    recipient = json.getString("recipient"),
                    inviteId = json.getString("invite_id"),
                    welcome = unb64(json.getString("welcome")),
                    ratchetTree = unb64(json.getString("ratchet_tree")),
                    signature = json.getString("signature"),
                ))
            }
            else -> error("unsupported relay payload")
        }
    }

    fun verifyWelcome(identity: NativeIdentity, payload: WelcomePayload, relaySender: String) {
        require(payload.senderInstallationId == relaySender) { "Welcome sender mismatch" }
        require(payload.recipient == identity.installationId()) { "Welcome recipient mismatch" }
        val public = unb64(payload.senderPublicKey)
        val installationId = b64(MessageDigest.getInstance("SHA-256").digest(public))
        require(installationId == payload.senderInstallationId) { "Welcome public identity mismatch" }
        val digest = MessageDigest.getInstance("SHA-256").digest(public)
        val fingerprint = digest.copyOfRange(0, 16).toList().chunked(2)
            .joinToString(" ") { chunk -> chunk.joinToString("") { "%02x".format(it.toInt() and 0xff) } }
        require(fingerprint == payload.senderFingerprint) { "Welcome fingerprint mismatch" }
        val welcome64 = b64(payload.welcome)
        val tree64 = b64(payload.ratchetTree)
        require(identity.verify(payload.senderPublicKey, signingBytes(
            payload.senderInstallationId,
            payload.senderPublicKey,
            payload.senderFingerprint,
            payload.senderNickname,
            payload.recipient,
            payload.inviteId,
            welcome64,
            tree64,
        ), payload.signature)) { "Welcome signature invalid" }
    }

    private fun encode(json: JSONObject): String = b64(json.toString().toByteArray(Charsets.UTF_8))

    private fun signingBytes(vararg values: String): ByteArray {
        val output = ByteArrayOutputStream()
        output.write("torchat-welcome-v1".toByteArray(Charsets.UTF_8))
        values.forEach { value ->
            val bytes = value.toByteArray(Charsets.UTF_8)
            output.write(ByteBuffer.allocate(4).putInt(bytes.size).array())
            output.write(bytes)
        }
        return output.toByteArray()
    }

    private fun b64(value: ByteArray): String =
        Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun unb64(value: String): ByteArray =
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}
