package org.torchat.mobile

import org.json.JSONObject

sealed class RuntimeSendEffect {
    enum class PairingKind(val wireValue: String) {
        OFFER("OFFER"),
        REJECTION("REJECTION"),
    }

    data class Message(
        val messageId: String,
        val conversationId: String,
        val recipientInstallationId: String,
        val body: String,
    ) : RuntimeSendEffect()

    data class Pairing(
        val pairingId: String,
        val recipientInstallationId: String,
        val kind: PairingKind,
        val payload: String?,
    ) : RuntimeSendEffect()

    companion object {
        fun fromJson(effect: JSONObject): RuntimeSendEffect =
            when {
                effect.has("messageId") -> Message(
                    messageId = effect.getString("messageId"),
                    conversationId = effect.getString("conversationId"),
                    recipientInstallationId = effect.getString("recipientInstallationId"),
                    body = effect.getString("body"),
                )
                effect.has("pairingId") -> Pairing(
                    pairingId = effect.getString("pairingId"),
                    recipientInstallationId = effect.getString("recipientInstallationId"),
                    kind = when (effect.getString("kind")) {
                        PairingKind.OFFER.wireValue -> PairingKind.OFFER
                        PairingKind.REJECTION.wireValue -> PairingKind.REJECTION
                        else -> error("unknown pairing send effect kind")
                    },
                    payload = if (effect.isNull("payload")) null else effect.getString("payload"),
                )
                else -> error("unknown runtime send effect")
            }
    }
}
