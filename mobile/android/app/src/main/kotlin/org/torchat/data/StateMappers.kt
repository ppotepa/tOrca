package org.torchat.data

import org.json.JSONObject
import org.torchat.core.NativeContactInvite
import org.torchat.transport.PairingInboxItem as RelayPairingInboxItem
import org.torchat.transport.PairingRequestCreated
import org.torchat.transport.WelcomePayload

private fun String.normalizedStateValue() = trim().uppercase()

private inline fun <reified T : Enum<T>> String.toCanonicalEnum(): T =
    enumValueOf(normalizedStateValue())

fun String.toContactSource(): ContactSource =
    toCanonicalEnum()

fun String.toConversationState(): ConversationState =
    toCanonicalEnum()

fun String.toMessageState(): MessageState =
    toCanonicalEnum()

fun String.toPairingState(): PairingState =
    toCanonicalEnum()

fun String.toLegacyConversationState(): ConversationState =
    when (normalizedStateValue()) {
        "NEW" -> ConversationState.PENDING
        else -> toConversationState()
    }

fun String.toLegacyMessageState(): MessageState =
    when (normalizedStateValue()) {
        "PENDING" -> MessageState.QUEUED
        "RECEIVED" -> MessageState.DELIVERED
        else -> toMessageState()
    }

fun String.toLegacyPairingState(): PairingState =
    when (normalizedStateValue()) {
        "CANCELED" -> PairingState.CANCELLED
        else -> toPairingState()
    }

fun LocalPairingInboxItem.toInboundContact() = LocalContact(
    installationId = senderInstallationId,
    nickname = senderNickname,
    publicKey = senderPublicKey,
    fingerprint = senderFingerprint,
    keyPackage = null,
    verification = ContactVerification.UNVERIFIED,
    source = ContactSource.INVITE,
)

fun NativeContactInvite.toLocalContact(source: ContactSource) = LocalContact(
    installationId = installationId,
    nickname = nickname ?: installationId,
    publicKey = publicKey,
    fingerprint = fingerprint,
    keyPackage = keyPackage,
    source = source,
)

fun RelayPairingInboxItem.toRuntimePairingItemJson() = JSONObject()
    .put("pairingId", pairingId)
    .put("expiresAt", expiresAt)
    .put("state", state.toLegacyPairingState().name)
    .put("received", true)
    .put("capability", capability)
    .put(
        "sender",
        JSONObject()
            .put("installationId", sender.installationId)
            .put("nickname", sender.nickname)
            .put("publicKey", sender.publicKey)
            .put("fingerprint", sender.fingerprint)
            .put("verification", ContactVerification.UNVERIFIED.name),
    )

fun PairingRequestCreated.toRuntimePairingItemJson() = JSONObject()
    .put("pairingId", pairingId)
    .put("expiresAt", expiresAt)
    .put("state", state.toLegacyPairingState().name)
    .put("received", false)

fun WelcomePayload.toLocalContact() = LocalContact(
    installationId = senderInstallationId,
    nickname = senderNickname,
    publicKey = senderPublicKey,
    fingerprint = senderFingerprint,
    keyPackage = null,
    verification = ContactVerification.UNVERIFIED,
    source = ContactSource.PAIRING,
)
