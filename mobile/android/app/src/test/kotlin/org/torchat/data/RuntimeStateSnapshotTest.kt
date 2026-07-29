package org.torchat.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.torchat.transport.PairingCode
import java.util.UUID

class RuntimeStateSnapshotTest {
    @Test
    fun `store snapshot emits canonical runtime dto names and states`() {
        val messageId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val store = SnapshotStore(
            contacts = listOf(
                LocalContact(
                    installationId = "peer-1",
                    nickname = "",
                    publicKey = "peer-pk",
                    fingerprint = "peer-fp",
                )
            ),
            conversations = listOf(
                LocalConversation(
                    id = "peer-1",
                    contactInstallationId = "peer-1",
                    status = ConversationState.PENDING,
                    unreadCount = 2,
                )
            ),
            messages = mapOf(
                "peer-1" to listOf(
                    ChatMessage(
                        id = messageId,
                        conversationId = "peer-1",
                        outgoing = true,
                        body = null,
                        ciphertext = byteArrayOf(1, 2, 3),
                        state = MessageState.QUEUED,
                        createdAt = 11,
                    )
                )
            ),
            inbox = listOf(
                LocalPairingInboxItem(
                    pairingId = "pairing-in",
                    senderInstallationId = "sender-1",
                    senderNickname = "",
                    senderPublicKey = "sender-pk",
                    senderFingerprint = "sender-fp",
                    capability = "chat",
                    expiresAt = 99,
                )
            ),
            outbox = listOf(LocalPairingOutboxItem("pairing-out", expiresAt = 100)),
        )

        val snapshot = JSONObject(
            store.toRuntimeStateSnapshotJson(
                identity = RuntimeStateIdentity("install-1", "pk", "fp"),
                nickname = "Alice",
                pairingCode = PairingCode("123456", 123),
            )
        )

        assertEquals("install-1", snapshot.getJSONObject("identity").getString("installationId"))
        assertEquals("Alice", snapshot.getJSONObject("profile").getString("nickname"))
        assertEquals("123456", snapshot.getJSONObject("pairingCode").getString("code"))
        assertEquals("peer-1", snapshot.getJSONArray("contacts").getJSONObject(0).getString("nickname"))
        assertEquals("PENDING", snapshot.getJSONArray("conversations").getJSONObject(0).getString("status"))
        assertEquals("QUEUED", snapshot.getJSONArray("messages").getJSONObject(0).getString("state"))
        assertEquals(true, snapshot.getJSONArray("pairingInbox").getJSONObject(0).getBoolean("received"))
        assertEquals(false, snapshot.getJSONArray("pairingOutbox").getJSONObject(0).getBoolean("received"))
    }

    @Test
    fun `store applies canonical runtime snapshot records`() {
        val messageId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val store = SnapshotStore()

        store.applyRuntimeStateSnapshotJson(
            JSONObject()
                .put(
                    "contacts",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("installationId", "peer-2")
                            .put("nickname", "")
                            .put("publicKey", "peer-pk")
                            .put("fingerprint", "peer-fp")
                            .put("verification", "VERIFIED"),
                    ),
                )
                .put(
                    "conversations",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("id", "peer-2")
                            .put("contactInstallationId", "peer-2")
                            .put("status", "ACTIVE")
                            .put("unreadCount", 0)
                            .put("lastMessagePreview", "hi")
                            .put("lastMessageAt", 44),
                    ),
                )
                .put(
                    "messages",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("id", messageId.toString())
                            .put("conversationId", "peer-2")
                            .put("outgoing", false)
                            .put("body", "hi")
                            .put("state", "DELIVERED")
                            .put("createdAt", 44),
                    ),
                )
                .put(
                    "pairingInbox",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("pairingId", "pairing-in")
                            .put(
                                "sender",
                                JSONObject()
                                    .put("installationId", "sender-2")
                                    .put("nickname", "")
                                    .put("publicKey", "sender-pk")
                                    .put("fingerprint", "sender-fp"),
                            )
                            .put("capability", "chat")
                            .put("expiresAt", 99)
                            .put("state", "ACCEPTED"),
                    ),
                )
                .put(
                    "pairingOutbox",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("pairingId", "pairing-out")
                            .put("expiresAt", 100)
                            .put("state", "CANCELLED"),
                    ),
                )
                .toString(),
        )

        assertEquals(ContactVerification.VERIFIED, store.contacts().single().verification)
        assertEquals("peer-2", store.contacts().single().nickname)
        assertEquals(ConversationState.ACTIVE, store.conversations().single().status)
        assertEquals(0, store.conversations().single().unreadCount)
        assertEquals(MessageState.DELIVERED, store.conversation("peer-2").single().state)
        assertEquals(PairingState.ACCEPTED, store.pairingInbox().single().state)
        assertEquals(PairingState.CANCELLED, store.pairingOutbox().single().state)
    }

    @Test
    fun `runtime snapshot preserves pairing accept offer artifacts`() {
        val store = SnapshotStore(
            inbox = listOf(
                LocalPairingInboxItem(
                    pairingId = "pairing-offer",
                    senderInstallationId = "sender-offer",
                    senderNickname = "Sender",
                    senderPublicKey = "sender-pk",
                    senderFingerprint = "sender-fp",
                    capability = "chat",
                    expiresAt = 99,
                    state = PairingState.ACCEPTED,
                    offerInviteId = "invite-offer",
                    offerPayload = "payload-json".toByteArray(Charsets.UTF_8),
                )
            ),
        )

        val snapshot = JSONObject(store.toRuntimeStateSnapshotJson(
            identity = RuntimeStateIdentity("install-1", "pk", "fp"),
            nickname = "Alice",
        ))
        val pairing = snapshot.getJSONArray("pairingInbox").getJSONObject(0)
        assertEquals("invite-offer", pairing.getString("offerInviteId"))
        assertEquals("payload-json", pairing.getString("offerPayload"))

        val imported = SnapshotStore()
        imported.applyRuntimeStateSnapshotJson(
            JSONObject()
                .put("pairingInbox", org.json.JSONArray().put(pairing))
                .toString(),
        )

        assertEquals("invite-offer", imported.pairingInbox().single().offerInviteId)
        assertEquals("payload-json", String(imported.pairingInbox().single().offerPayload!!, Charsets.UTF_8))
    }

    @Test
    fun `runtime snapshot merge preserves local message ciphertext and relay id`() {
        val messageId = UUID.fromString("00000000-0000-0000-0000-000000000011")
        val ciphertext = byteArrayOf(9, 8, 7)
        val store = SnapshotStore(
            conversations = listOf(LocalConversation("peer-merge", "peer-merge")),
            messages = mapOf(
                "peer-merge" to listOf(
                    ChatMessage(
                        id = messageId,
                        conversationId = "peer-merge",
                        outgoing = true,
                        body = "old",
                        ciphertext = ciphertext,
                        state = MessageState.SENT,
                        createdAt = 12,
                        remoteMessageId = "relay-id",
                    )
                )
            ),
        )

        store.applyRuntimeStateSnapshotJson(
            JSONObject()
                .put(
                    "messages",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("id", messageId.toString())
                            .put("conversationId", "peer-merge")
                            .put("outgoing", true)
                            .put("body", "new")
                            .put("state", "DELIVERED")
                            .put("createdAt", 12),
                    ),
                )
                .toString(),
        )

        val message = store.conversation("peer-merge").single()
        assertEquals(MessageState.DELIVERED, message.state)
        assertEquals("new", message.body)
        assertEquals(ciphertext.toList(), message.ciphertext.toList())
        assertEquals("relay-id", message.remoteMessageId)
    }

    @Test
    fun `runtime snapshot merge preserves local conversation mls state`() {
        val mlsState = byteArrayOf(6, 5, 4)
        val store = SnapshotStore(
            conversations = listOf(
                LocalConversation(
                    id = "peer-state",
                    contactInstallationId = "peer-state",
                    state = mlsState,
                    status = ConversationState.VERIFYING,
                    unreadCount = 3,
                )
            ),
        )

        store.applyRuntimeStateSnapshotJson(
            JSONObject()
                .put(
                    "conversations",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("id", "peer-state")
                            .put("contactInstallationId", "peer-state")
                            .put("status", "ACTIVE")
                            .put("unreadCount", 0)
                            .put("lastMessagePreview", "ready")
                            .put("lastMessageAt", 123),
                    ),
                )
                .toString(),
        )

        val conversation = store.conversations().single()
        assertEquals(ConversationState.ACTIVE, conversation.status)
        assertEquals(0, conversation.unreadCount)
        assertEquals(mlsState.toList(), conversation.state?.toList())
    }

    @Test
    fun `runtime command adapter imports dispatches exports and applies state`() {
        val store = SnapshotStore(
            contacts = listOf(
                LocalContact(
                    installationId = "peer-3",
                    nickname = "Peer",
                    publicKey = "peer-pk",
                    fingerprint = "peer-fp",
                )
            ),
            conversations = listOf(
                LocalConversation(
                    id = "peer-3",
                    contactInstallationId = "peer-3",
                    status = ConversationState.ACTIVE,
                    unreadCount = 4,
                )
            ),
        )
        val dispatcher = FakeRuntimeDispatcher(
            events = org.json.JSONArray().put(
                JSONObject()
                    .put("type", "conversation_read_changed")
                    .put("conversationId", "peer-3")
                    .put("unreadCount", 0),
            ),
        ) { imported, request ->
            assertEquals("openConversation", request.getString("method"))
            assertEquals("peer-3", request.getJSONObject("params").getString("id"))
            val conversations = imported.getJSONArray("conversations")
            conversations.getJSONObject(0).put("unreadCount", 0)
            imported
        }

        val response = store.applyRuntimeCommand(
            dispatcher = dispatcher,
            identity = RuntimeStateIdentity("install-1", "pk", "fp"),
            nickname = "Alice",
            method = "openConversation",
            params = JSONObject().put("id", "peer-3"),
        )

        assertEquals(true, response.response.getBoolean("ok"))
        assertEquals("conversation_read_changed", response.events.single()["type"])
        assertEquals("peer-3", response.events.single()["conversationId"])
        assertEquals(1, dispatcher.importCount)
        assertEquals(1, dispatcher.dispatchCount)
        assertEquals(1, dispatcher.exportCount)
        assertEquals(0, store.conversations().single().unreadCount)
    }

    @Test
    fun `runtime command adapter can mark selected conversation before receive command`() {
        val store = SnapshotStore(
            conversations = listOf(
                LocalConversation(
                    id = "peer-selected",
                    contactInstallationId = "peer-selected",
                    status = ConversationState.ACTIVE,
                    unreadCount = 2,
                )
            ),
        )
        val methods = mutableListOf<String>()
        val dispatcher = FakeRuntimeDispatcher { imported, request ->
            methods += request.getString("method")
            when (request.getString("method")) {
                "openConversation" -> {
                    imported.getJSONArray("conversations").getJSONObject(0).put("unreadCount", 0)
                    imported
                }
                "receiveMessage" -> {
                    assertEquals(0, imported.getJSONArray("conversations").getJSONObject(0).getInt("unreadCount"))
                    imported
                }
                else -> imported
            }
        }

        store.applyRuntimeCommand(
            dispatcher = dispatcher,
            identity = RuntimeStateIdentity("install-1", "pk", "fp"),
            nickname = "Alice",
            method = "receiveMessage",
            params = JSONObject().put("id", "peer-selected").put("text", "hi"),
        )

        assertEquals(listOf("openConversation", "receiveMessage"), methods)
        assertEquals(2, dispatcher.dispatchCount)
    }

    @Test
    fun `runtime command result exposes canonical array result as maps`() {
        val result = RuntimeCommandResult(
            response = JSONObject()
                .put("ok", true)
                .put(
                    "result",
                    org.json.JSONArray().put(
                        JSONObject()
                            .put("pairingId", "pairing-1")
                            .put("state", "PENDING"),
                    ),
                ),
            events = emptyList(),
        )

        assertEquals("pairing-1", result.resultArrayAsMaps().single()["pairingId"])
        assertEquals("PENDING", result.resultArrayAsMaps().single()["state"])
    }

    @Test
    fun `runtime command adapter applies archived pairing state`() {
        val store = SnapshotStore(
            inbox = listOf(
                LocalPairingInboxItem(
                    pairingId = "pairing-archive",
                    senderInstallationId = "sender-3",
                    senderNickname = "Sender",
                    senderPublicKey = "sender-pk",
                    senderFingerprint = "sender-fp",
                    capability = "chat",
                    expiresAt = 99,
                    state = PairingState.REJECTED,
                )
            ),
        )
        val dispatcher = FakeRuntimeDispatcher { imported, request ->
            assertEquals("archivePairing", request.getString("method"))
            assertEquals("pairing-archive", request.getJSONObject("params").getString("pairingId"))
            imported.getJSONArray("pairingInbox").getJSONObject(0).put("state", "ARCHIVED")
            imported
        }

        store.applyRuntimeCommand(
            dispatcher = dispatcher,
            identity = RuntimeStateIdentity("install-1", "pk", "fp"),
            nickname = "Alice",
            method = "archivePairing",
            params = JSONObject().put("pairingId", "pairing-archive"),
        )

        assertEquals(PairingState.ARCHIVED, store.pairingInbox().single().state)
    }
}

private class FakeRuntimeDispatcher(
    private val events: org.json.JSONArray = org.json.JSONArray(),
    private val transform: (JSONObject, JSONObject) -> JSONObject,
) : RuntimeJsonDispatcher {
    var importCount = 0
        private set
    var dispatchCount = 0
        private set
    var exportCount = 0
        private set
    private var imported = JSONObject()
    private var exported = JSONObject()

    override fun importStateJson(stateJson: String): String {
        importCount += 1
        imported = JSONObject(stateJson)
        exported = imported
        return "true"
    }

    override fun dispatchJson(requestJson: String): String {
        dispatchCount += 1
        exported = transform(imported, JSONObject(requestJson))
        return JSONObject().put("ok", true).put("result", true).toString()
    }

    override fun exportStateJson(): String {
        exportCount += 1
        return exported.toString()
    }

    override fun drainEventsJson(): String = events.toString()
}

private class SnapshotStore(
    contacts: List<LocalContact> = emptyList(),
    conversations: List<LocalConversation> = emptyList(),
    messages: Map<String, List<ChatMessage>> = emptyMap(),
    inbox: List<LocalPairingInboxItem> = emptyList(),
    outbox: List<LocalPairingOutboxItem> = emptyList(),
) : MessageStore {
    private val contacts = contacts.toMutableList()
    private val conversations = conversations.toMutableList()
    private val messages = messages.mapValues { it.value.toMutableList() }.toMutableMap()
    private val inbox = inbox.toMutableList()
    private val outbox = outbox.toMutableList()
    private val receivedEnvelopes = mutableListOf<ReceivedEnvelope>()
    private val deliveryReceipts = mutableListOf<DeliveryReceiptRecord>()

    override fun put(message: ChatMessage) {
        val list = messages.getOrPut(message.conversationId) { mutableListOf() }
        list.removeAll { it.id == message.id }
        list += message
    }
    override fun message(id: UUID): ChatMessage? =
        messages.values.asSequence().flatten().firstOrNull { it.id == id }
    override fun pending(): List<ChatMessage> = emptyList()
    override fun claimMessageRetry(
        messageId: UUID,
        nowMs: Long,
        nextAttemptAt: Long,
        ackDeadline: Long?,
        lastError: String?,
    ): Boolean = false
    override fun requeueSendingAfterDisconnect(nowMs: Long) = Unit
    override fun conversation(id: String): List<ChatMessage> = messages[id].orEmpty()
    override fun contacts(): List<LocalContact> = contacts.toList()
    override fun contact(installationId: String): LocalContact? = contacts.firstOrNull { it.installationId == installationId }
    override fun putContact(contact: LocalContact) {
        contacts.removeAll { it.installationId == contact.installationId }
        contacts += contact
    }
    override fun conversations(): List<LocalConversation> = conversations.toList()
    override fun conversationState(id: String): LocalConversation? = conversations.firstOrNull { it.id == id }
    override fun putConversation(conversation: LocalConversation) {
        conversations.removeAll { it.id == conversation.id }
        conversations += conversation
    }
    override fun putMlsInbox(state: ByteArray) = Unit
    override fun mlsInbox(): ByteArray? = null
    override fun consumeInvite(inviteId: String): Boolean = false
    override fun isInviteConsumed(inviteId: String): Boolean = false
    override fun pairingInbox(): List<LocalPairingInboxItem> = inbox.toList()
    override fun putPairingInbox(item: LocalPairingInboxItem) {
        inbox.removeAll { it.pairingId == item.pairingId }
        inbox += item
    }
    override fun pairingInboxItem(pairingId: String): LocalPairingInboxItem? = inbox.firstOrNull { it.pairingId == pairingId }
    override fun removePairingInbox(pairingId: String) = Unit
    override fun pairingOutbox(): List<LocalPairingOutboxItem> = outbox.toList()
    override fun putPairingOutbox(item: LocalPairingOutboxItem) {
        outbox.removeAll { it.pairingId == item.pairingId }
        outbox += item
    }
    override fun pendingWelcomes(): List<LocalPendingWelcome> = emptyList()
    override fun putPendingWelcome(value: LocalPendingWelcome) = Unit
    override fun receivedEnvelope(senderInstallationId: String, messageId: String): ReceivedEnvelope? =
        receivedEnvelopes.firstOrNull {
            it.senderInstallationId == senderInstallationId && it.messageId == messageId
        }
    override fun putReceivedEnvelope(value: ReceivedEnvelope) {
        receivedEnvelopes.removeAll {
            it.senderInstallationId == value.senderInstallationId && it.messageId == value.messageId
        }
        receivedEnvelopes += value
    }
    override fun pendingReceivedEnvelope(): List<ReceivedEnvelope> =
        receivedEnvelopes.filter { it.receiptState.uppercase() == "PENDING" }
    override fun putDeliveryReceipt(value: DeliveryReceiptRecord) {
        deliveryReceipts.removeAll { it.messageId == value.messageId }
        deliveryReceipts += value
    }
    override fun pendingDeliveryReceipts(nowMs: Long): List<DeliveryReceiptRecord> =
        deliveryReceipts.filter {
            it.state.uppercase() in setOf("PENDING", "SENT") && it.nextAttemptAt <= nowMs
        }
    override fun claimDeliveryReceiptRetry(
        messageId: String,
        nowMs: Long,
        nextAttemptAt: Long,
        lastError: String?,
    ): Boolean {
        val existing = deliveryReceipts.firstOrNull { it.messageId == messageId } ?: return false
        if (existing.state.uppercase() !in setOf("PENDING", "SENT") || existing.nextAttemptAt > nowMs) {
            return false
        }
        putDeliveryReceipt(
            existing.copy(
                state = "SENT",
                attemptCount = existing.attemptCount + 1,
                nextAttemptAt = nextAttemptAt,
                lastError = lastError,
            )
        )
        return true
    }
}
