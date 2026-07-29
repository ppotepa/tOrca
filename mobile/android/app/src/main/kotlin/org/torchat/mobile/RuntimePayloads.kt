package org.torchat.mobile

import org.torchat.core.NativeIdentity
import org.torchat.data.ChatMessage
import org.torchat.data.LocalContact
import org.torchat.data.LocalConversation
import org.torchat.data.LocalPairingInboxItem
import org.torchat.data.LocalPairingOutboxItem
import org.torchat.transport.PairingCode
import org.torchat.transport.PairingInboxItem
import org.torchat.transport.PairingRequestCreated
import org.torchat.transport.ProfileResponse

private fun runtimeContactCard(
    installationId: String,
    nickname: String,
    publicKey: String,
    fingerprint: String,
) = mapOf(
    "installationId" to installationId,
    "nickname" to nickname,
    "publicKey" to publicKey,
    "fingerprint" to fingerprint,
)

private fun runtimePairingItem(
    pairingId: String,
    sender: Map<String, Any?>? = null,
    capability: String? = null,
    expiresAt: Long,
    state: Any,
    received: Boolean,
) = mapOf(
    "pairingId" to pairingId,
    "sender" to sender,
    "capability" to capability,
    "expiresAt" to expiresAt,
    "state" to state,
    "received" to received,
    "availableActions" to runtimePairingAvailableActions(state.toString(), received),
)

private fun runtimePairingAvailableActions(state: String, received: Boolean): List<String> =
    when (state.trim().uppercase()) {
        "PENDING" -> if (received) listOf("ACCEPT", "REJECT") else listOf("CANCEL")
        "ACCEPTED" -> if (received) emptyList() else listOf("CANCEL")
        "REJECTED", "COMPLETED", "EXPIRED", "CANCELLED" -> listOf("ARCHIVE")
        else -> emptyList()
    }

private fun runtimeProfileCard(
    installationId: String,
    fingerprint: String,
    nickname: String? = null,
    publicKey: String? = null,
) = buildMap {
    put("installationId", installationId)
    put("fingerprint", fingerprint)
    if (nickname != null) {
        put("nickname", nickname)
    }
    if (publicKey != null) {
        put("publicKey", publicKey)
    }
}

fun runtimeIdentityInfo(identity: NativeIdentity) = runtimeProfileCard(
    installationId = identity.installationId(),
    fingerprint = identity.fingerprint(),
)

fun runtimeProfileResponse(
    installationId: String,
    publicKey: String,
    fingerprint: String,
    nickname: String?,
) = ProfileResponse(
    installationId = installationId,
    nickname = nickname,
    publicKey = publicKey,
    fingerprint = fingerprint,
)

fun runtimeProfileResponse(identity: NativeIdentity, nickname: String?) =
    runtimeProfileResponse(
        installationId = identity.installationId(),
        publicKey = identity.publicKey(),
        fingerprint = identity.fingerprint(),
        nickname = nickname,
    )

fun ProfileResponse.withNickname(nickname: String?) = copy(nickname = nickname)

fun <T> Iterable<T>?.toRuntimeMapList(
    transform: (T) -> Map<String, Any?>,
): List<Map<String, Any?>> = this?.map(transform).orEmpty()

fun PairingCode.toRuntimeMap() = mapOf(
    "code" to code,
    "expiresAt" to expiresAt,
)

fun PairingRequestCreated.toRuntimeMap() = mapOf(
    "pairingId" to pairingId,
    "expiresAt" to expiresAt,
    "state" to state,
    "received" to false,
)

fun PairingInboxItem.toRuntimeMap() =
    runtimePairingItem(
        pairingId = pairingId,
        sender = runtimeContactCard(
            installationId = sender.installationId,
            nickname = sender.nickname,
            publicKey = sender.publicKey,
            fingerprint = sender.fingerprint,
        ),
        capability = capability,
        expiresAt = expiresAt,
        state = state,
        received = true,
    )

fun LocalPairingInboxItem.toRuntimeMap() =
    runtimePairingItem(
        pairingId = pairingId,
        sender = runtimeContactCard(
            installationId = senderInstallationId,
            nickname = senderNickname,
            publicKey = senderPublicKey,
            fingerprint = senderFingerprint,
        ),
        capability = capability,
        expiresAt = expiresAt,
        state = state.name,
        received = true,
    )

fun LocalPairingOutboxItem.toRuntimeMap() =
    runtimePairingItem(
        pairingId = pairingId,
        expiresAt = expiresAt,
        state = state.name,
        received = false,
    )

fun LocalContact.toRuntimeMap() = mapOf(
    "installationId" to installationId,
    "nickname" to nickname,
    "publicKey" to publicKey,
    "fingerprint" to fingerprint,
    "verification" to verification.name,
    "dev" to devFixture,
)

fun LocalConversation.toRuntimeMap() = mapOf(
    "id" to id,
    "contactInstallationId" to contactInstallationId,
    "status" to status.name,
    "unreadCount" to unreadCount,
    "lastMessagePreview" to lastMessagePreview,
    "lastMessageAt" to lastMessageAt,
)

fun ChatMessage.toRuntimeMap() = mapOf(
    "id" to id.toString(),
    "conversationId" to conversationId,
    "outgoing" to outgoing,
    "body" to body,
    "state" to state.name,
    "createdAt" to createdAt,
    "attemptCount" to attemptCount,
    "lastAttemptAt" to lastAttemptAt,
    "nextAttemptAt" to nextAttemptAt,
    "ackDeadline" to ackDeadline,
    "lastTransportError" to lastTransportError,
    "error" to error,
)

fun ProfileResponse.toRuntimeMap() = runtimeProfileCard(
    installationId = installationId,
    fingerprint = fingerprint,
    nickname = nickname,
    publicKey = publicKey,
)
