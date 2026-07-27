package org.torchat.transport

data class ProfileResponse(
    val installationId: String,
    val nickname: String?,
    val publicKey: String,
    val fingerprint: String,
)

data class ContactCard(
    val installationId: String,
    val nickname: String,
    val publicKey: String,
    val fingerprint: String,
)

data class PairingCode(
    val code: String,
    val expiresAt: Long,
)

data class PairingInboxItem(
    val pairingId: String,
    val sender: ContactCard,
    val capability: String,
    val expiresAt: Long,
)
