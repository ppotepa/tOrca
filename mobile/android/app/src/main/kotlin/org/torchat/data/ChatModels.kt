package org.torchat.data

import java.util.UUID

enum class MessageState { QUEUED, SENDING, SENT, DELIVERED, FAILED }
enum class ContactVerification { UNVERIFIED, VERIFIED }
enum class ContactSource { PAIRING, INVITE, QR, DEV }
enum class ConversationState { PENDING, VERIFYING, ACTIVE, OFFLINE, FAILED }

data class LocalContact(
    val installationId: String,
    val nickname: String,
    val publicKey: String,
    val fingerprint: String,
    val keyPackage: ByteArray? = null,
    val verification: ContactVerification = ContactVerification.UNVERIFIED,
    val source: ContactSource = ContactSource.PAIRING,
    val devFixture: String? = null,
)

data class LocalConversation(
    val id: String,
    val contactInstallationId: String,
    val state: ByteArray? = null,
    val status: ConversationState = ConversationState.PENDING,
    val unreadCount: Int = 0,
    val lastMessagePreview: String? = null,
    val lastMessageAt: Long? = null,
)

data class ChatMessage(
    val id: UUID,
    val conversationId: String,
    val outgoing: Boolean,
    val body: String?,
    val ciphertext: ByteArray,
    val state: MessageState,
    val createdAt: Long,
    val remoteMessageId: String? = null,
    val error: String? = null,
    val attemptCount: Int = 0,
    val lastAttemptAt: Long? = null,
    val nextAttemptAt: Long = 0L,
    val ackDeadline: Long? = null,
    val lastTransportError: String? = null,
)

enum class PairingState { PENDING, ACCEPTED, REJECTED, COMPLETED, EXPIRED, ARCHIVED, CANCELLED }

data class LocalPairingInboxItem(
    val pairingId: String,
    val senderInstallationId: String,
    val senderNickname: String,
    val senderPublicKey: String,
    val senderFingerprint: String,
    val capability: String,
    val expiresAt: Long,
    val state: PairingState = PairingState.PENDING,
    val offerInviteId: String? = null,
    val offerPayload: ByteArray? = null,
)

data class LocalPairingOutboxItem(
    val pairingId: String,
    val expiresAt: Long,
    val state: PairingState = PairingState.PENDING,
)

data class LocalPendingWelcome(
    val inviteId: String,
    val recipientInstallationId: String,
    val payload: ByteArray,
    val expiresAt: Long,
)

data class ReceivedEnvelope(
    val senderInstallationId: String,
    val messageId: String,
    val ciphertextHash: ByteArray,
    val receivedAt: Long,
    val receiptState: String,
)

data class DeliveryReceiptRecord(
    val messageId: String,
    val originalSender: String,
    val state: String,
    val attemptCount: Int = 0,
    val nextAttemptAt: Long = 0L,
    val createdAt: Long,
    val lastError: String? = null,
)

/** The relay never owns this queue; it is deliberately a client-only concern. */
interface MessageStore : AutoCloseable {
    override fun close() = Unit

    fun put(message: ChatMessage)
    fun message(id: UUID): ChatMessage?
    fun pending(): List<ChatMessage>
    fun claimMessageRetry(messageId: UUID, nowMs: Long, nextAttemptAt: Long, ackDeadline: Long?, lastError: String? = null): Boolean
    fun requeueSendingAfterDisconnect(nowMs: Long)
    fun conversation(id: String): List<ChatMessage>
    fun contacts(): List<LocalContact>
    fun contact(installationId: String): LocalContact?
    fun putContact(contact: LocalContact)
    fun conversations(): List<LocalConversation>
    fun conversationState(id: String): LocalConversation?
    fun putConversation(conversation: LocalConversation)
    fun putMlsInbox(state: ByteArray)
    fun mlsInbox(): ByteArray?
    fun consumeInvite(inviteId: String): Boolean
    fun isInviteConsumed(inviteId: String): Boolean
    fun pairingInbox(): List<LocalPairingInboxItem>
    fun putPairingInbox(item: LocalPairingInboxItem)
    fun pairingInboxItem(pairingId: String): LocalPairingInboxItem?
    fun removePairingInbox(pairingId: String)
    fun pairingOutbox(): List<LocalPairingOutboxItem>
    fun putPairingOutbox(item: LocalPairingOutboxItem)
    fun pendingWelcomes(): List<LocalPendingWelcome>
    fun putPendingWelcome(value: LocalPendingWelcome)
    fun receivedEnvelope(senderInstallationId: String, messageId: String): ReceivedEnvelope?
    fun putReceivedEnvelope(value: ReceivedEnvelope)
    fun pendingReceivedEnvelope(): List<ReceivedEnvelope>
    fun putDeliveryReceipt(value: DeliveryReceiptRecord)
    fun pendingDeliveryReceipts(nowMs: Long): List<DeliveryReceiptRecord>
    fun claimDeliveryReceiptRetry(messageId: String, nowMs: Long, nextAttemptAt: Long, lastError: String? = null): Boolean
}
