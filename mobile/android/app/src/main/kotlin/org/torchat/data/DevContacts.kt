package org.torchat.data

import android.content.Context
import android.util.Base64
import org.torchat.core.NativeIdentity
import org.torchat.mobile.BuildConfig

object DevContacts {
    private const val PREFS = "torchat-dev-contacts"
    private const val SEEDED = "alice-bob-seeded"

    /** Local-only fixtures. They are never uploaded to the server. */
    fun seed(context: Context): List<LocalContact> {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(SEEDED, true)
            .apply()
        if (!BuildConfig.DEBUG || BuildConfig.TORCHAT_DEV_PEER_KEY.isBlank()) return emptyList()
        val seed = Base64.decode(
            BuildConfig.TORCHAT_DEV_PEER_KEY,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        return NativeIdentity.fromPrivateKey(seed).use { peer ->
            listOf(LocalContact(
                installationId = peer.installationId(),
                nickname = BuildConfig.TORCHAT_DEV_PEER_NAME,
                publicKey = peer.publicKey(),
                fingerprint = peer.fingerprint(),
                source = ContactSource.DEV,
                devFixture = "android-peer",
            ))
        }
    }
}
