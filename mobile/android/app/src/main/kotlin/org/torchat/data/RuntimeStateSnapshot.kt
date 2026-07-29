package org.torchat.data

import org.json.JSONArray
import org.json.JSONObject
import org.torchat.transport.PairingCode
import java.util.UUID

data class RuntimeStateIdentity(
    val installationId: String,
    val publicKey: String,
    val fingerprint: String,
)

fun MessageStore.toRuntimeStateSnapshotJson(
    identity: RuntimeStateIdentity,
    nickname: String,
    pairingCode: PairingCode? = null,
): String = JSONObject()
    .put("identity", identity.toRuntimeJson())
    .put(
        "profile",
        JSONObject()
            .put("installationId", identity.installationId)
            .put("nickname", nickname)
            .put("publicKey", identity.publicKey)
            .put("fingerprint", identity.fingerprint),
    )
    .put("pairingCode", pairingCode?.toRuntimeJson())
    .put("pairingInbox", JSONArray(pairingInbox().map { it.toRuntimeJson() }))
    .put("pairingOutbox", JSONArray(pairingOutbox().map { it.toRuntimeJson() }))
    .put("contacts", JSONArray(contacts().map { it.toRuntimeJson() }))
    .put("conversations", JSONArray(conversations().map { it.toRuntimeJson() }))
    .put("messages", JSONArray(conversations().flatMap { conversation(it.id) }.map { it.toRuntimeJson() }))
    .toString()

fun MessageStore.applyRuntimeStateSnapshotJson(stateJson: String) {
    val snapshot = JSONObject(stateJson)
    snapshot.optJSONArray("contacts").forEachObject { putContact(it.toLocalContact()) }
    snapshot.optJSONArray("conversations").forEachObject { conversationJson ->
        putConversation(conversationJson.toLocalConversation(conversationState(conversationJson.getString("id"))))
    }
    snapshot.optJSONArray("messages").forEachObject { messageJson ->
        put(messageJson.toChatMessage(existingMessage(messageJson.getString("id"))))
    }
    snapshot.optJSONArray("pairingInbox").forEachObject { putPairingInbox(it.toLocalPairingInboxItem()) }
    snapshot.optJSONArray("pairingOutbox").forEachObject { putPairingOutbox(it.toLocalPairingOutboxItem()) }
}

private inline fun JSONArray?.forEachObject(action: (JSONObject) -> Unit) {
    if (this == null) return
    for (index in 0 until length()) {
        action(getJSONObject(index))
    }
}

private inline fun <reified T : Enum<T>> String.toSnapshotEnumOrDefault(default: T): T =
    runCatching { enumValueOf<T>(trim().uppercase()) }.getOrDefault(default)

private fun RuntimeStateIdentity.toRuntimeJson() = JSONObject()
    .put("installationId", installationId)
    .put("publicKey", publicKey)
    .put("fingerprint", fingerprint)

private fun PairingCode.toRuntimeJson() = JSONObject()
    .put("code", code)
    .put("expiresAt", expiresAt)

private fun LocalContact.toRuntimeJson() = JSONObject()
    .put("installationId", installationId)
    .put("nickname", nickname.ifBlank { installationId })
    .put("publicKey", publicKey)
    .put("fingerprint", fingerprint)
    .put("verification", verification.name)
    .apply {
        devFixture?.let { put("dev", it) }
    }

private fun LocalConversation.toRuntimeJson() = JSONObject()
    .put("id", id)
    .put("contactInstallationId", contactInstallationId)
    .put("status", status.name)
    .put("lastMessagePreview", lastMessagePreview.orEmpty())
    .put("lastMessageAt", lastMessageAt ?: 0L)
    .put("unreadCount", unreadCount.coerceAtLeast(0))

private fun ChatMessage.toRuntimeJson() = JSONObject()
    .put("id", id.toString())
    .put("conversationId", conversationId)
    .put("outgoing", outgoing)
    .put("body", body.orEmpty())
    .put("state", state.name)
    .put("createdAt", createdAt)
    .put("attemptCount", attemptCount)
    .put("lastAttemptAt", lastAttemptAt)
    .put("nextAttemptAt", nextAttemptAt)
    .put("ackDeadline", ackDeadline)
    .put("lastTransportError", lastTransportError)
    .apply {
        remoteMessageId?.let { put("remoteMessageId", it) }
        error?.let { put("error", it) }
    }

private fun LocalPairingInboxItem.toRuntimeJson() = JSONObject()
    .put("pairingId", pairingId)
    .put(
        "sender",
        JSONObject()
            .put("installationId", senderInstallationId)
            .put("nickname", senderNickname.ifBlank { senderInstallationId })
            .put("publicKey", senderPublicKey)
            .put("fingerprint", senderFingerprint)
            .put("verification", ContactVerification.UNVERIFIED.name),
    )
    .put("capability", capability)
    .put("expiresAt", expiresAt)
    .put("state", state.name)
    .put("received", true)
    .put("availableActions", JSONArray(pairingAvailableActions(state.name, received = true)))
    .apply {
        offerInviteId?.let { put("offerInviteId", it) }
        offerPayload?.let { put("offerPayload", String(it, Charsets.UTF_8)) }
    }

private fun LocalPairingOutboxItem.toRuntimeJson() = JSONObject()
    .put("pairingId", pairingId)
    .put("expiresAt", expiresAt)
    .put("state", state.name)
    .put("received", false)
    .put("availableActions", JSONArray(pairingAvailableActions(state.name, received = false)))

private fun pairingAvailableActions(state: String, received: Boolean): List<String> =
    when (state.trim().uppercase()) {
        "PENDING" -> if (received) listOf("ACCEPT", "REJECT") else listOf("CANCEL")
        "ACCEPTED" -> if (received) emptyList() else listOf("CANCEL")
        "REJECTED", "COMPLETED", "EXPIRED", "CANCELLED" -> listOf("ARCHIVE")
        else -> emptyList()
    }

private fun JSONObject.toLocalContact() = LocalContact(
    installationId = getString("installationId"),
    nickname = optString("nickname").ifBlank { getString("installationId") },
    publicKey = getString("publicKey"),
    fingerprint = getString("fingerprint"),
    verification = optString("verification", ContactVerification.UNVERIFIED.name)
        .toSnapshotEnumOrDefault(ContactVerification.UNVERIFIED),
    source = ContactSource.PAIRING,
    devFixture = optString("dev").takeIf { it.isNotBlank() },
)

private fun JSONObject.toLocalConversation(existing: LocalConversation?) = LocalConversation(
    id = getString("id"),
    contactInstallationId = getString("contactInstallationId"),
    state = existing?.state,
    status = optString("status", ConversationState.PENDING.name).toConversationState(),
    unreadCount = optInt("unreadCount", 0).coerceAtLeast(0),
    lastMessagePreview = optString("lastMessagePreview").takeIf { it.isNotBlank() },
    lastMessageAt = if (has("lastMessageAt") && !isNull("lastMessageAt")) optLong("lastMessageAt") else null,
)

private fun MessageStore.existingMessage(id: String): ChatMessage? =
    conversations().asSequence()
        .flatMap { conversation(it.id).asSequence() }
        .firstOrNull { it.id.toString() == id }

private fun JSONObject.toChatMessage(existing: ChatMessage?) = ChatMessage(
    id = UUID.fromString(getString("id")),
    conversationId = getString("conversationId"),
    outgoing = optBoolean("outgoing", false),
    body = optString("body").takeIf { it.isNotBlank() } ?: existing?.body,
    ciphertext = existing?.ciphertext ?: ByteArray(0),
    state = optString("state", MessageState.QUEUED.name).toMessageState(),
    createdAt = optLong("createdAt", 0L),
    remoteMessageId = optString("remoteMessageId").takeIf { it.isNotBlank() } ?: existing?.remoteMessageId,
    error = optString("error").takeIf { it.isNotBlank() } ?: existing?.error,
    attemptCount = optInt("attemptCount", existing?.attemptCount ?: 0),
    lastAttemptAt = if (has("lastAttemptAt") && !isNull("lastAttemptAt")) optLong("lastAttemptAt") else existing?.lastAttemptAt,
    nextAttemptAt = optLong("nextAttemptAt", existing?.nextAttemptAt ?: 0L),
    ackDeadline = if (has("ackDeadline") && !isNull("ackDeadline")) optLong("ackDeadline") else existing?.ackDeadline,
    lastTransportError = optString("lastTransportError").takeIf { it.isNotBlank() } ?: existing?.lastTransportError,
)

private fun JSONObject.toLocalPairingInboxItem(): LocalPairingInboxItem {
    val sender = getJSONObject("sender")
    return LocalPairingInboxItem(
        pairingId = getString("pairingId"),
        senderInstallationId = sender.getString("installationId"),
        senderNickname = sender.optString("nickname").ifBlank { sender.getString("installationId") },
        senderPublicKey = sender.getString("publicKey"),
        senderFingerprint = sender.getString("fingerprint"),
        capability = optString("capability"),
        expiresAt = optLong("expiresAt", 0L),
        state = optString("state", PairingState.PENDING.name).toPairingState(),
        offerInviteId = optString("offerInviteId").takeIf { it.isNotBlank() },
        offerPayload = optString("offerPayload").takeIf { it.isNotBlank() }?.toByteArray(Charsets.UTF_8),
    )
}

private fun JSONObject.toLocalPairingOutboxItem() = LocalPairingOutboxItem(
    pairingId = getString("pairingId"),
    expiresAt = optLong("expiresAt", 0L),
    state = optString("state", PairingState.PENDING.name).toPairingState(),
)
