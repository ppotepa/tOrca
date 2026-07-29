package org.torchat.mobile

import org.torchat.core.NativeIdentity
import org.torchat.transport.ProfileResponse

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

fun ProfileResponse.toRuntimeMap() = runtimeProfileCard(
    installationId = installationId,
    fingerprint = fingerprint,
    nickname = nickname,
    publicKey = publicKey,
)
