package org.torchat.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Uses an Android Keystore AES key to protect the SQLCipher database key. */
class LocalSecretStore(private val context: Context) {
    private val alias = "torchat-local-db-wrap-v1"
    private val prefs = context.getSharedPreferences("torchat-secrets", Context.MODE_PRIVATE)

    fun databasePassphrase(): ByteArray {
        val key = key()
        val encoded = prefs.getString("db-passphrase", null)
        if (encoded == null) {
            val raw = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            val encrypted = encrypt(key, raw)
            prefs.edit()
                .putString(
                    "db-passphrase",
                    android.util.Base64.encodeToString(encrypted, android.util.Base64.NO_WRAP),
                )
                .apply()
            return raw
        }
        return decrypt(key, android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP))
    }

    fun identityPrivateKey(): ByteArray {
        val key = key()
        val encoded = prefs.getString("identity-private-key", null)
        if (encoded == null) {
            val raw = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            val encrypted = encrypt(key, raw)
            prefs.edit()
                .putString(
                    "identity-private-key",
                    android.util.Base64.encodeToString(encrypted, android.util.Base64.NO_WRAP),
                )
                .apply()
            return raw
        }
        return decrypt(key, android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP))
    }

    fun nickname(): String? = prefs.getString("nickname", null)

    fun saveNickname(value: String) {
        prefs.edit().putString("nickname", value.trim()).apply()
    }

    fun clearLocalSecrets() {
        prefs.edit().clear().commit()
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) store.deleteEntry(alias)
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(alias)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(
                    KeyGenParameterSpec.Builder(
                        alias,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build(),
                )
                generateKey()
            }
        }
        return (store.getEntry(alias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    private fun encrypt(key: SecretKey, value: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key)
        }
        return cipher.iv + cipher.doFinal(value)
    }

    private fun decrypt(key: SecretKey, value: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, value.copyOfRange(0, 12)))
        return cipher.doFinal(value.copyOfRange(12, value.size))
    }
}
