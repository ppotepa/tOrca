package org.torchat.chat

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.torchat.data.ChatMessage
import org.torchat.data.ContactSource
import org.torchat.data.ConversationState
import org.torchat.data.LocalContact
import org.torchat.data.LocalConversation
import org.torchat.data.MessageState
import org.torchat.data.MessageStore
import org.torchat.transport.AndroidRelayTransport
import org.torchat.core.NativeConversation
import org.torchat.core.NativeIdentity
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Owns the Android-side chat flow; MLS state remains in Rust through C ABI. */
class ChatController(
    private val identity: NativeIdentity,
    private val store: MessageStore,
    private val relay: AndroidRelayTransport,
    private val devFixtures: Map<String, ByteArray> = emptyMap(),
    initialNickname: String = "Alice",
) {
    private val conversations = ConcurrentHashMap<String, NativeConversation>()
    @Volatile private var activeConversationId: String? = null
    @Volatile private var ownNickname: String = initialNickname

    init {
        store.conversations().forEach { saved ->
            val state = saved.state ?: return@forEach
            runCatching { identity.restoreConversation(state) }
                .onSuccess { conversations[saved.contactInstallationId] = it }
        }
    }

    fun contactInvitePayload(): String = identity.contactInvitePayload(ownNickname).also {
        store.putMlsInbox(identity.mlsSnapshot())
    }

    suspend fun bootstrapAndConnect() = withContext(Dispatchers.IO) {
        bootstrapRelay()
        connectRelay()
    }

    suspend fun bootstrapRelay() = withContext(Dispatchers.IO) { relay.bootstrap() }

    suspend fun connectRelay() = withContext(Dispatchers.IO) {
        relay.connect()
        retryPendingMessages()
    }

    suspend fun loadProfile() = relay.profile().also { profile ->
        profile.nickname?.takeIf { it.isNotBlank() }?.let { ownNickname = it }
    }

    suspend fun updateNickname(nickname: String) = relay.updateNickname(nickname).also {
        ownNickname = nickname
    }

    suspend fun searchContacts(query: String) = relay.searchDirectory(query)

    fun localContacts(): List<LocalContact> = store.contacts()

    fun localConversations(): List<LocalConversation> = store.conversations()

    fun messages(conversationId: String): List<ChatMessage> = store.conversation(conversationId)

    fun addContact(contact: LocalContact) {
        store.putContact(contact)
    }

    suspend fun startDevConversation(contact: LocalContact) = withContext(Dispatchers.IO) {
        conversations[contact.installationId]?.let {
            activeConversationId = contact.installationId
            store.markRead(contact.installationId)
            return@withContext
        }
        val fixture = contact.devFixture?.let(devFixtures::get)
            ?: error("brak debugowego fixture dla kontaktu")
        val chat = identity.restoreConversation(fixture)
        conversations[contact.installationId] = chat
        activeConversationId = contact.installationId
        storeConversation(contact.installationId, contact.installationId, chat, ConversationState.ACTIVE)
    }

    suspend fun startConversation(contact: LocalContact) = withContext(Dispatchers.IO) {
        conversations[contact.installationId]?.let {
            activeConversationId = contact.installationId
            store.markRead(contact.installationId)
            return@withContext
        }
        if (contact.devFixture != null) return@withContext startDevConversation(contact)
        val keyPackage = contact.keyPackage
            ?: error("Ten kontakt nie ma jeszcze pakietu MLS. Rozpocznij rozmowę przez QR.")
        val chat = identity.createConversation()
        val welcome = chat.invite(keyPackage)
        conversations[contact.installationId] = chat
        activeConversationId = contact.installationId
        storeConversation(contact.installationId, contact.installationId, chat, ConversationState.ACTIVE)
        relay.send(contact.installationId, RelayPayloads.welcome(
            identity, ownNickname, contact.installationId, welcome[0], welcome[1],
        ))
    }

    fun openConversation(conversationId: String) {
        activeConversationId = conversationId
        store.markRead(conversationId)
    }

    fun activeConversationId(): String? = activeConversationId

    suspend fun startConversation(invitePayload: String) = withContext(Dispatchers.IO) {
        val invite = NativeIdentity.parseContactInvite(invitePayload)
        check(!store.isInviteConsumed(invite.inviteId)) { "zaproszenie zostało już użyte" }
        store.putContact(LocalContact(
            installationId = invite.installationId,
            nickname = invite.nickname ?: invite.installationId,
            publicKey = invite.publicKey,
            fingerprint = invite.fingerprint,
            keyPackage = invite.keyPackage,
            source = ContactSource.QR,
        ))
        val chat = identity.createConversation()
        val welcome = chat.invite(invite.keyPackage)
        conversations[invite.installationId] = chat
        activeConversationId = invite.installationId
        storeConversation(invite.installationId, invite.installationId, chat, ConversationState.ACTIVE)
        if (!relay.send(invite.installationId, RelayPayloads.welcome(
            identity, ownNickname, invite.installationId, welcome[0], welcome[1],
        ))) {
            error("nie udało się wysłać zaproszenia przez Tor")
        }
        check(store.consumeInvite(invite.inviteId)) { "zaproszenie zostało już użyte" }
    }

    suspend fun receive(sender: String, encoded: String): String? = withContext(Dispatchers.IO) {
        when (val payload = RelayPayloads.decode(encoded)) {
          is DecodedRelayPayload.Welcome -> {
            RelayPayloads.verifyWelcome(identity, payload.value, sender)
            val chat = identity.acceptConversation(
                payload.value.welcome,
                payload.value.ratchetTree,
            )
            store.putMlsInbox(identity.mlsSnapshot())
            conversations[sender] = chat
            activeConversationId = sender
            store.putContact(LocalContact(
                installationId = payload.value.senderInstallationId,
                nickname = payload.value.senderNickname,
                publicKey = payload.value.senderPublicKey,
                fingerprint = payload.value.senderFingerprint,
                source = ContactSource.QR,
            ))
            storeConversation(sender, sender, chat, ConversationState.ACTIVE)
            return@withContext null
          }
          is DecodedRelayPayload.Application -> {
            val chat = conversations[sender] ?: error("received message before MLS Welcome")
            val plaintext = chat.decrypt(payload.ciphertext)
            val text = String(plaintext, Charsets.UTF_8)
            val conversation = store.conversationState(sender) ?: LocalConversation(sender, sender, status = ConversationState.ACTIVE)
            storeConversation(sender, conversation.contactInstallationId, chat, ConversationState.ACTIVE, conversation)
            store.putConversation((store.conversationState(sender) ?: conversation).copy(
                status = ConversationState.ACTIVE,
                unreadCount = if (activeConversationId == sender) 0 else conversation.unreadCount + 1,
                lastMessagePreview = text,
                lastMessageAt = System.currentTimeMillis(),
            ))
            store.put(ChatMessage(UUID.randomUUID(), sender, false, text, payload.ciphertext, MessageState.DELIVERED, System.currentTimeMillis()))
            text
          }
        }
    }

    suspend fun receiveLoop(
        onText: (String) -> Unit,
        onWelcome: suspend () -> Unit = {},
        onStateChanged: suspend () -> Unit = {},
    ) {
        while (true) {
            val frame = JSONObject(relay.nextFrame())
            when (frame.optString("type")) {
                "envelope" -> {
                    val sender = frame.getString("sender")
                    val text = receive(sender, frame.getString("ciphertext"))
                    if (text != null) onText(text) else onWelcome()
                    relay.sendReceipt(frame.getString("message_id"), sender)
                }
                "delivery_receipt" -> {
                    store.markRemoteState(frame.getString("message_id"), MessageState.DELIVERED)
                    onStateChanged()
                }
                "forwarded" -> Unit
                "recipient_offline" -> {
                    store.markRemoteState(frame.getString("message_id"), MessageState.FAILED)
                    onStateChanged()
                }
                "error" -> error("relay error: ${frame.optString("code")}")
            }
        }
    }

    suspend fun send(text: String) = send(activeConversationId ?: error("no conversation selected"), text)

    suspend fun send(conversationId: String, text: String) = withContext(Dispatchers.IO) {
        val recipient = store.conversationState(conversationId)?.contactInstallationId
            ?: error("conversation not found")
        val chat = conversations[recipient] ?: error("MLS conversation is not established")
        val encrypted = chat.encrypt(text.toByteArray(Charsets.UTF_8))
        storeConversation(conversationId, recipient, chat, ConversationState.ACTIVE, store.conversationState(conversationId))
        val id = UUID.randomUUID()
        val now = System.currentTimeMillis()
        store.put(ChatMessage(id, conversationId, true, text, encrypted, MessageState.PENDING, now))
        store.putConversation((store.conversationState(conversationId)
            ?: LocalConversation(conversationId, recipient)).copy(
            status = ConversationState.ACTIVE,
            lastMessagePreview = text,
            lastMessageAt = now,
        ))
        val remoteId = relay.sendWithId(
            id.toString(),
            recipient,
            RelayPayloads.application(encrypted),
        )
        if (remoteId != null) {
            store.put(ChatMessage(id, conversationId, true, text, encrypted, MessageState.SENT, now, remoteId))
        }
    }

    suspend fun retryPendingMessages() = withContext(Dispatchers.IO) {
        store.pending().forEach { message ->
            val recipient = store.conversationState(message.conversationId)?.contactInstallationId ?: return@forEach
            val remoteId = relay.sendWithId(
                message.id.toString(),
                recipient,
                RelayPayloads.application(message.ciphertext),
            ) ?: return@forEach
            store.put(message.copy(state = MessageState.SENT, remoteMessageId = remoteId, error = null))
        }
    }

    private fun storeConversation(
        conversationId: String,
        contactInstallationId: String,
        chat: NativeConversation,
        status: ConversationState,
        existing: LocalConversation? = null,
    ) {
        val state = runCatching { chat.snapshot() }.getOrNull()
        store.putConversation((existing ?: LocalConversation(conversationId, contactInstallationId)).copy(
            state = state,
            status = status,
        ))
    }
}
