package org.torchat.chat

import org.json.JSONObject
import java.util.UUID

sealed interface ApplicationPayload {
    data class Message(
        val version: Int,
        val messageId: UUID,
        val sentAt: Long,
        val body: String,
    ) : ApplicationPayload

    data class DeliveryReceipt(
        val version: Int,
        val messageId: UUID,
        val receivedAt: Long,
    ) : ApplicationPayload

    companion object {
        fun encode(payload: ApplicationPayload): String =
            when (payload) {
                is Message -> JSONObject().apply {
                    put("kind", "message")
                    put("version", payload.version)
                    put("messageId", payload.messageId.toString())
                    put("sentAt", payload.sentAt)
                    put("body", payload.body)
                }.toString()
                is DeliveryReceipt -> JSONObject().apply {
                    put("kind", "delivery_receipt")
                    put("version", payload.version)
                    put("messageId", payload.messageId.toString())
                    put("receivedAt", payload.receivedAt)
                }.toString()
            }

        fun decode(text: String): ApplicationPayload {
            val json = JSONObject(text)
            require(json.getInt("version") == 1) { "unsupported application payload version" }
            return when (json.getString("kind")) {
                "message" -> Message(
                    version = json.getInt("version"),
                    messageId = UUID.fromString(json.getString("messageId")),
                    sentAt = json.getLong("sentAt"),
                    body = json.getString("body"),
                )
                "delivery_receipt" -> DeliveryReceipt(
                    version = json.getInt("version"),
                    messageId = UUID.fromString(json.getString("messageId")),
                    receivedAt = json.getLong("receivedAt"),
                )
                else -> error("unsupported application payload")
            }
        }
    }
}
