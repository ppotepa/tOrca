package org.torchat.transport

data class ProfileResponse(
    val installationId: String,
    val nickname: String?,
    val publicKey: String,
    val fingerprint: String,
)
