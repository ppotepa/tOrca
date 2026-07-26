package org.torchat.core

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.Structure

private interface CoreLibrary : Library {
    fun torchat_last_error(): Pointer?
    fun torchat_free_string(value: Pointer?)
    fun torchat_free_bytes(value: NativeBytes)
    fun torchat_free_pair(value: NativePair)
    fun torchat_identity_from_private_key(data: ByteArray, len: Long): Pointer?
    fun torchat_identity_generate(): Pointer?
    fun torchat_identity_free(value: Pointer?)
    fun torchat_identity_installation_id(value: Pointer?): Pointer?
    fun torchat_identity_public_key(value: Pointer?): Pointer?
    fun torchat_identity_fingerprint(value: Pointer?): Pointer?
    fun torchat_identity_sign(value: Pointer?, data: ByteArray, len: Long): Pointer?
    fun torchat_verify_signature(publicKey: ByteArray, publicKeyLen: Long, data: ByteArray, dataLen: Long, signature: ByteArray, signatureLen: Long): Int
    fun torchat_identity_contact_invite(value: Pointer?): Pointer?
    fun torchat_identity_contact_invite_with_nickname(value: Pointer?, nickname: ByteArray, nicknameLen: Long): Pointer?
    fun torchat_identity_mls_snapshot(value: Pointer?): NativeBytes
    fun torchat_identity_restore_mls(value: Pointer?, data: ByteArray, len: Long): Int
    fun torchat_validate_contact_invite(data: ByteArray, len: Long): Int
    fun torchat_contact_invite_key_package(data: ByteArray, len: Long): NativeBytes
    fun torchat_conversation_create(identity: Pointer?): Pointer?
    fun torchat_conversation_restore(data: ByteArray, len: Long): Pointer?
    fun torchat_conversation_accept(identity: Pointer?, welcome: ByteArray, welcomeLen: Long, tree: ByteArray, treeLen: Long): Pointer?
    fun torchat_conversation_free(value: Pointer?)
    fun torchat_conversation_invite(value: Pointer?, keyPackage: ByteArray, len: Long): NativePair
    fun torchat_conversation_encrypt(value: Pointer?, data: ByteArray, len: Long): NativeBytes
    fun torchat_conversation_decrypt(value: Pointer?, data: ByteArray, len: Long): NativeBytes
    fun torchat_conversation_snapshot(value: Pointer?): NativeBytes
}

@Structure.FieldOrder("data", "len")
open class NativeBytes : Structure(), Structure.ByValue {
    @JvmField var data: Pointer? = null
    @JvmField var len: Long = 0
}

@Structure.FieldOrder("first", "second")
open class NativePair : Structure(), Structure.ByValue {
    @JvmField var first = NativeBytes()
    @JvmField var second = NativeBytes()
}

private object Core {
    val api: CoreLibrary = Native.load("torchat_core", CoreLibrary::class.java)

    fun error(): String = api.torchat_last_error()?.let { pointer ->
        val value = pointer.getString(0)
        api.torchat_free_string(pointer)
        value
    } ?: "Rust core operation failed"

    fun requirePointer(pointer: Pointer?): Pointer = pointer ?: error(Core.error())

    fun string(pointer: Pointer?): String = requirePointer(pointer).let {
        val value = it.getString(0)
        api.torchat_free_string(it)
        value
    }

    fun bytes(value: NativeBytes): ByteArray {
        value.read()
        val pointer = value.data
        if (pointer == null || value.len == 0L) {
            api.torchat_free_bytes(value)
            return ByteArray(0)
        }
        val result = pointer.getByteArray(0, value.len.toInt())
        api.torchat_free_bytes(value)
        return result
    }
}

data class NativeContactInvite(
    val installationId: String,
    val publicKey: String,
    val fingerprint: String,
    val nickname: String?,
    val keyPackage: ByteArray,
    val inviteId: String,
    val expiresAt: Long,
)

class NativeIdentity private constructor(internal val handle: Pointer) : AutoCloseable {
    fun installationId() = Core.string(Core.api.torchat_identity_installation_id(handle))
    fun publicKey() = Core.string(Core.api.torchat_identity_public_key(handle))
    fun fingerprint() = Core.string(Core.api.torchat_identity_fingerprint(handle))
    fun sign(data: ByteArray) = Core.string(Core.api.torchat_identity_sign(handle, data, data.size.toLong()))
    fun verify(publicKey: String, data: ByteArray, signature: String): Boolean {
        val key = publicKey.toByteArray(Charsets.UTF_8)
        val proof = signature.toByteArray(Charsets.UTF_8)
        return Core.api.torchat_verify_signature(key, key.size.toLong(), data, data.size.toLong(), proof, proof.size.toLong()) == 1
    }
    fun contactInvitePayload(nickname: String? = null): String {
        if (nickname.isNullOrBlank()) return Core.string(Core.api.torchat_identity_contact_invite(handle))
        val value = nickname.toByteArray(Charsets.UTF_8)
        return Core.string(Core.api.torchat_identity_contact_invite_with_nickname(handle, value, value.size.toLong()))
    }
    fun mlsSnapshot(): ByteArray = Core.bytes(Core.api.torchat_identity_mls_snapshot(handle))
    fun restoreMls(snapshot: ByteArray) {
        check(Core.api.torchat_identity_restore_mls(handle, snapshot, snapshot.size.toLong()) == 1) {
            Core.error()
        }
    }

    fun createConversation() = NativeConversation(Core.requirePointer(Core.api.torchat_conversation_create(handle)))
    fun restoreConversation(snapshot: ByteArray) = NativeConversation(Core.requirePointer(Core.api.torchat_conversation_restore(snapshot, snapshot.size.toLong())))
    fun acceptConversation(welcome: ByteArray, tree: ByteArray) = NativeConversation(Core.requirePointer(Core.api.torchat_conversation_accept(handle, welcome, welcome.size.toLong(), tree, tree.size.toLong())))

    override fun close() = Core.api.torchat_identity_free(handle)

    companion object {
        fun fromPrivateKey(seed: ByteArray) = NativeIdentity(Core.requirePointer(Core.api.torchat_identity_from_private_key(seed, seed.size.toLong())))
        fun generate() = NativeIdentity(Core.requirePointer(Core.api.torchat_identity_generate()))

        fun parseContactInvite(value: String): NativeContactInvite {
            val encoded = value.toByteArray(Charsets.UTF_8)
            if (Core.api.torchat_validate_contact_invite(encoded, encoded.size.toLong()) != 1) throw IllegalArgumentException(Core.error())
            val json = org.json.JSONObject(value)
            return NativeContactInvite(
                installationId = json.getString("installation_id"),
                publicKey = json.getString("public_key"),
                fingerprint = json.getString("fingerprint"),
                nickname = json.optString("nickname").takeIf { it.isNotBlank() },
                keyPackage = Core.bytes(Core.api.torchat_contact_invite_key_package(encoded, encoded.size.toLong())),
                inviteId = json.getString("invite_id"),
                expiresAt = json.getLong("expires_at"),
            )
        }
    }
}

class NativeConversation internal constructor(private val handle: Pointer) : AutoCloseable {
    fun invite(keyPackage: ByteArray): List<ByteArray> {
        val pair = Core.api.torchat_conversation_invite(handle, keyPackage, keyPackage.size.toLong())
        pair.first.read(); pair.second.read()
        val first = Core.bytes(pair.first)
        val second = Core.bytes(pair.second)
        return listOf(first, second)
    }
    fun encrypt(data: ByteArray) = Core.bytes(Core.api.torchat_conversation_encrypt(handle, data, data.size.toLong()))
    fun decrypt(data: ByteArray) = Core.bytes(Core.api.torchat_conversation_decrypt(handle, data, data.size.toLong()))
    fun snapshot() = Core.bytes(Core.api.torchat_conversation_snapshot(handle))
    override fun close() = Core.api.torchat_conversation_free(handle)
}
