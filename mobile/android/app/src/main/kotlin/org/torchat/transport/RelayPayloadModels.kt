package org.torchat.transport

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
