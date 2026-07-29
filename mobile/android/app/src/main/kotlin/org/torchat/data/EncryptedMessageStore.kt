package org.torchat.data

import android.content.Context
import android.database.Cursor
import net.sqlcipher.database.SQLiteDatabase
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** SQLCipher-backed local state. No server message cache is mirrored here. */
class EncryptedMessageStore(context: Context, passphrase: ByteArray) : MessageStore {
    init { SQLiteDatabase.loadLibs(context) }

    private val sql = SqlCatalog(context)

    private val db = SQLiteDatabase.openOrCreateDatabase(
        File(context.noBackupFilesDir, "torchat-local.db").absolutePath, passphrase, null
    ).apply { migrate(this) }

    override fun close() {
        if (db.isOpen) db.close()
    }

    private fun migrate(database: SQLiteDatabase) {
        database.execSQL(sql.get("migrations/000_schema_migrations.sql"))
        val migrations = listOf(
            "001_initial.sql" to null,
            "002_messages_remote_message_id.sql" to ("messages" to "remote_message_id"),
            "003_messages_error.sql" to ("messages" to "error"),
            "004_pairing_offer_payload.sql" to ("pairing_inbox" to "offer_payload"),
            "005_pairing_outbox.sql" to null,
            "006_canonical_state_values.sql" to null,
            "007_expiry_seconds.sql" to null,
            "008_received_envelopes.sql" to null,
            "009_delivery_receipts.sql" to ("delivery_receipts" to "message_id"),
            "010_message_retry_metadata.sql" to ("messages" to "attempt_count"),
        )
        migrations.forEach { (name, optionalColumn) ->
            val applied = database.rawQuery(sql.get("queries/migration_lookup.sql"), arrayOf(name)).use { it.moveToFirst() }
            if (applied) return@forEach
            val alreadyPresent = optionalColumn?.let { hasColumn(database, it.first, it.second) } ?: false
            if (!alreadyPresent) sql.statements("migrations/$name").forEach(database::execSQL)
            database.execSQL(sql.get("queries/migration_insert.sql"), arrayOf<Any?>(name, System.currentTimeMillis()))
        }
    }

    private fun hasColumn(database: SQLiteDatabase, table: String, column: String): Boolean =
        database.rawQuery(sql.get("queries/table_columns.sql"), arrayOf(table)).use { cursor ->
            val nameColumn = cursor.getColumnIndexOrThrow("name")
            generateSequence { if (cursor.moveToNext()) cursor.getString(nameColumn) else null }.any { it == column }
        }

    override fun put(message: ChatMessage) {
        db.execSQL(sql.get("queries/message_upsert.sql"), arrayOf(
            message.id.toString(), message.conversationId, if (message.outgoing) 1 else 0,
            message.body, message.ciphertext, message.state.name, message.createdAt,
            message.remoteMessageId, message.error, message.attemptCount,
            message.lastAttemptAt, message.nextAttemptAt, message.ackDeadline,
            message.lastTransportError,
        ))
    }

    override fun message(id: UUID): ChatMessage? =
        db.rawQuery(sql.get("queries/message_get.sql"), arrayOf(id.toString())).use { cursor ->
            if (cursor.moveToFirst()) cursor.message() else null
        }

    override fun pending(): List<ChatMessage> =
        query(sql.get("queries/messages_pending.sql"), arrayOf(System.currentTimeMillis().toString()))

    override fun claimMessageRetry(
        messageId: UUID,
        nowMs: Long,
        nextAttemptAt: Long,
        ackDeadline: Long?,
        lastError: String?,
    ): Boolean {
        db.execSQL(
            "UPDATE messages SET state = 'SENDING', attempt_count = attempt_count + 1, last_attempt_at = ?, next_attempt_at = ?, ack_deadline = ?, last_transport_error = ? WHERE id = ? AND outgoing = 1 AND UPPER(state) IN ('QUEUED', 'SENT') AND next_attempt_at <= ?",
            arrayOf<Any?>(nowMs, nextAttemptAt, ackDeadline, lastError, messageId.toString(), nowMs),
        )
        return db.rawQuery("SELECT changes()", null).use { cursor ->
            cursor.moveToFirst() && cursor.getLong(0) > 0L
        }
    }

    override fun requeueSendingAfterDisconnect(nowMs: Long) {
        db.execSQL(
            "UPDATE messages SET state = 'QUEUED', next_attempt_at = ?, ack_deadline = NULL WHERE outgoing = 1 AND UPPER(state) = 'SENDING'",
            arrayOf(nowMs),
        )
    }

    override fun conversation(id: String): List<ChatMessage> =
        query(sql.get("queries/messages_conversation.sql"), arrayOf(id))

    override fun contacts(): List<LocalContact> = buildList {
        db.rawQuery(sql.get("queries/contacts_list.sql"), null).use { cursor ->
            while (cursor.moveToNext()) add(cursor.contact())
        }
    }

    override fun contact(installationId: String): LocalContact? =
        db.rawQuery(sql.get("queries/contact_get.sql"), arrayOf(installationId)).use { cursor ->
            if (cursor.moveToFirst()) cursor.contact() else null
        }

    override fun putContact(contact: LocalContact) {
        db.execSQL(sql.get("queries/contact_upsert.sql"),
            arrayOf(contact.installationId, contact.nickname, contact.publicKey, contact.fingerprint,
                contact.keyPackage, contact.verification.name, contact.source.name,
                contact.installationId, System.currentTimeMillis()))
    }

    override fun conversations(): List<LocalConversation> = buildList {
        db.rawQuery(sql.get("queries/conversations_list.sql"), null).use { cursor ->
            while (cursor.moveToNext()) add(cursor.localConversation())
        }
    }

    override fun conversationState(id: String): LocalConversation? =
        db.rawQuery(sql.get("queries/conversation_get.sql"), arrayOf(id)).use { cursor ->
            if (cursor.moveToFirst()) cursor.localConversation() else null
        }

    override fun putConversation(conversation: LocalConversation) {
        db.execSQL(sql.get("queries/conversation_upsert.sql"), arrayOf(conversation.id, conversation.contactInstallationId,
                conversation.state, conversation.status.name, conversation.unreadCount,
                conversation.lastMessagePreview, conversation.lastMessageAt))
    }

    override fun putMlsInbox(state: ByteArray) {
        db.execSQL(sql.get("queries/setting_upsert.sql"), arrayOf("mls-inbox-v1", state))
    }

    override fun mlsInbox(): ByteArray? =
        db.rawQuery(sql.get("queries/setting_get.sql"), arrayOf("mls-inbox-v1")).use { cursor ->
            if (cursor.moveToFirst()) cursor.getBlob(0) else null
        }

    override fun consumeInvite(inviteId: String): Boolean {
        db.rawQuery(sql.get("queries/invite_get.sql"), arrayOf(inviteId)).use { cursor ->
            if (cursor.moveToFirst()) return false
        }
        db.execSQL(sql.get("queries/invite_insert.sql"), arrayOf<Any?>(inviteId, System.currentTimeMillis()))
        return true
    }

    override fun isInviteConsumed(inviteId: String): Boolean =
        db.rawQuery(sql.get("queries/invite_get.sql"), arrayOf(inviteId)).use { cursor ->
            cursor.moveToFirst()
        }

    override fun pairingInbox(): List<LocalPairingInboxItem> = buildList {
        db.rawQuery(sql.get("queries/pairing_list.sql"), null).use { cursor ->
            while (cursor.moveToNext()) add(cursor.pairingInboxItem())
        }
    }

    override fun pairingInboxItem(pairingId: String): LocalPairingInboxItem? =
        db.rawQuery(sql.get("queries/pairing_get.sql"), arrayOf(pairingId)).use { cursor ->
            if (cursor.moveToFirst()) cursor.pairingInboxItem() else null
        }

    override fun putPairingInbox(item: LocalPairingInboxItem) {
        db.execSQL(sql.get("queries/pairing_upsert.sql"), arrayOf(
            item.pairingId, item.senderInstallationId, item.senderNickname, item.senderPublicKey,
            item.senderFingerprint, item.capability, item.expiresAt, item.state.name, item.offerInviteId, item.offerPayload,
        ))
    }

    override fun removePairingInbox(pairingId: String) {
        db.execSQL(sql.get("queries/pairing_delete.sql"), arrayOf(pairingId))
    }

    override fun pairingOutbox(): List<LocalPairingOutboxItem> = buildList {
        db.rawQuery(sql.get("queries/pairing_outbox_list.sql"), null).use { cursor ->
            while (cursor.moveToNext()) add(LocalPairingOutboxItem(
                pairingId = cursor.getString(cursor.getColumnIndexOrThrow("pairing_id")),
                expiresAt = cursor.getLong(cursor.getColumnIndexOrThrow("expires_at")),
                state = cursor.getString(cursor.getColumnIndexOrThrow("state")).toPairingState(),
            ))
        }
    }

    override fun putPairingOutbox(item: LocalPairingOutboxItem) {
        db.execSQL(sql.get("queries/pairing_outbox_upsert.sql"), arrayOf<Any?>(item.pairingId, item.expiresAt, item.state.name))
    }

    override fun pendingWelcomes(): List<LocalPendingWelcome> {
        val raw = db.rawQuery(sql.get("queries/setting_get.sql"), arrayOf("pending-welcomes-v1"))
            .use { cursor -> if (cursor.moveToFirst()) cursor.getBlob(0) else null }
            ?: return emptyList()
        val values = runCatching { JSONArray(String(raw, Charsets.UTF_8)) }.getOrNull() ?: return emptyList()
        return buildList {
            for (index in 0 until values.length()) {
                val item = values.optJSONObject(index) ?: continue
                val payload = runCatching {
                    android.util.Base64.decode(item.getString("payload"), android.util.Base64.NO_WRAP)
                }.getOrNull() ?: continue
                add(LocalPendingWelcome(item.getString("inviteId"), item.getString("recipient"), payload, item.getLong("expiresAt")))
            }
        }
    }

    override fun putPendingWelcome(value: LocalPendingWelcome) {
        val values = pendingWelcomes().filterNot { it.inviteId == value.inviteId }.toMutableList()
        values += value
        val json = JSONArray().apply {
            values.forEach { item ->
                put(JSONObject().apply {
                    put("inviteId", item.inviteId)
                    put("recipient", item.recipientInstallationId)
                    put("payload", android.util.Base64.encodeToString(item.payload, android.util.Base64.NO_WRAP))
                    put("expiresAt", item.expiresAt)
                })
            }
        }
        db.execSQL(sql.get("queries/setting_upsert.sql"), arrayOf("pending-welcomes-v1", json.toString().toByteArray(Charsets.UTF_8)))
    }

    override fun receivedEnvelope(senderInstallationId: String, messageId: String): ReceivedEnvelope? =
        db.rawQuery(
            "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state FROM received_envelopes WHERE sender_installation_id = ? AND message_id = ?",
            arrayOf(senderInstallationId, messageId),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            ReceivedEnvelope(
                senderInstallationId = cursor.getString(0),
                messageId = cursor.getString(1),
                ciphertextHash = cursor.getBlob(2),
                receivedAt = cursor.getLong(3),
                receiptState = cursor.getString(4),
            )
        }

    override fun putReceivedEnvelope(value: ReceivedEnvelope) {
        db.execSQL(
            "INSERT OR REPLACE INTO received_envelopes (sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state) VALUES (?, ?, ?, ?, ?)",
            arrayOf<Any?>(
                value.senderInstallationId,
                value.messageId,
                value.ciphertextHash,
                value.receivedAt,
                value.receiptState,
            ),
        )
    }

    override fun pendingReceivedEnvelope(): List<ReceivedEnvelope> = buildList {
        db.rawQuery(
            "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state FROM received_envelopes WHERE UPPER(receipt_state) = 'PENDING' ORDER BY received_at, message_id",
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                add(
                    ReceivedEnvelope(
                        senderInstallationId = cursor.getString(0),
                        messageId = cursor.getString(1),
                        ciphertextHash = cursor.getBlob(2),
                        receivedAt = cursor.getLong(3),
                        receiptState = cursor.getString(4),
                    )
                )
            }
        }
    }

    override fun putDeliveryReceipt(value: DeliveryReceiptRecord) {
        db.execSQL(
            "INSERT OR REPLACE INTO delivery_receipts (message_id, original_sender, state, attempt_count, next_attempt_at, created_at, last_error) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arrayOf<Any?>(
                value.messageId,
                value.originalSender,
                value.state,
                value.attemptCount,
                value.nextAttemptAt,
                value.createdAt,
                value.lastError,
            ),
        )
    }

    override fun pendingDeliveryReceipts(nowMs: Long): List<DeliveryReceiptRecord> = buildList {
        db.rawQuery(
            "SELECT message_id, original_sender, state, attempt_count, next_attempt_at, created_at, last_error FROM delivery_receipts WHERE UPPER(state) IN ('PENDING', 'SENT') AND next_attempt_at <= ? ORDER BY next_attempt_at, created_at, message_id",
            arrayOf(nowMs.toString()),
        ).use { cursor ->
            while (cursor.moveToNext()) {
                add(
                    DeliveryReceiptRecord(
                        messageId = cursor.getString(0),
                        originalSender = cursor.getString(1),
                        state = cursor.getString(2),
                        attemptCount = cursor.getInt(3),
                        nextAttemptAt = cursor.getLong(4),
                        createdAt = cursor.getLong(5),
                        lastError = if (cursor.isNull(6)) null else cursor.getString(6),
                    )
                )
            }
        }
    }

    override fun claimDeliveryReceiptRetry(
        messageId: String,
        nowMs: Long,
        nextAttemptAt: Long,
        lastError: String?,
    ): Boolean {
        db.execSQL(
            "UPDATE delivery_receipts SET state = 'SENT', attempt_count = attempt_count + 1, next_attempt_at = ?, last_error = ? WHERE message_id = ? AND UPPER(state) IN ('PENDING', 'SENT') AND next_attempt_at <= ?",
            arrayOf<Any?>(nextAttemptAt, lastError, messageId, nowMs),
        )
        return db.rawQuery(
            "SELECT changes()",
            null,
        ).use { cursor -> cursor.moveToFirst() && cursor.getLong(0) > 0L }
    }

    private fun query(statementSql: String, args: Array<String>): List<ChatMessage> {
        val result = mutableListOf<ChatMessage>()
        db.rawQuery(statementSql, args).use { cursor ->
            while (cursor.moveToNext()) result += cursor.message()
        }
        return result
    }

    private fun Cursor.message() = ChatMessage(
        UUID.fromString(getString(getColumnIndexOrThrow("id"))),
        getString(getColumnIndexOrThrow("conversation_id")),
        getInt(getColumnIndexOrThrow("outgoing")) != 0,
        getString(getColumnIndexOrThrow("body")),
        getBlob(getColumnIndexOrThrow("ciphertext")),
        getString(getColumnIndexOrThrow("state")).toMessageState(),
        getLong(getColumnIndexOrThrow("created_at")),
        getString(getColumnIndexOrThrow("remote_message_id")),
        getString(getColumnIndexOrThrow("error")),
        getInt(getColumnIndexOrThrow("attempt_count")),
        if (isNull(getColumnIndexOrThrow("last_attempt_at"))) null else getLong(getColumnIndexOrThrow("last_attempt_at")),
        getLong(getColumnIndexOrThrow("next_attempt_at")),
        if (isNull(getColumnIndexOrThrow("ack_deadline"))) null else getLong(getColumnIndexOrThrow("ack_deadline")),
        getString(getColumnIndexOrThrow("last_transport_error")),
    )

    private fun Cursor.contact() = LocalContact(
        getString(getColumnIndexOrThrow("installation_id")),
        getString(getColumnIndexOrThrow("nickname")),
        getString(getColumnIndexOrThrow("public_key")),
        getString(getColumnIndexOrThrow("fingerprint")),
        getBlob(getColumnIndexOrThrow("key_package")),
        ContactVerification.valueOf(getString(getColumnIndexOrThrow("verification"))),
        getString(getColumnIndexOrThrow("source")).toContactSource(),
    )

    private fun Cursor.localConversation() = LocalConversation(
        getString(getColumnIndexOrThrow("id")),
        getString(getColumnIndexOrThrow("contact_installation_id")),
        getBlob(getColumnIndexOrThrow("mls_state")),
        getString(getColumnIndexOrThrow("status")).toConversationState(),
        getInt(getColumnIndexOrThrow("unread_count")),
        getString(getColumnIndexOrThrow("last_message_preview")),
        if (isNull(getColumnIndexOrThrow("last_message_at"))) null else getLong(getColumnIndexOrThrow("last_message_at")),
    )

    private fun Cursor.pairingInboxItem() = LocalPairingInboxItem(
        pairingId = getString(getColumnIndexOrThrow("pairing_id")),
        senderInstallationId = getString(getColumnIndexOrThrow("sender_installation_id")),
        senderNickname = getString(getColumnIndexOrThrow("sender_nickname")),
        senderPublicKey = getString(getColumnIndexOrThrow("sender_public_key")),
        senderFingerprint = getString(getColumnIndexOrThrow("sender_fingerprint")),
        capability = getString(getColumnIndexOrThrow("capability")),
        expiresAt = getLong(getColumnIndexOrThrow("expires_at")),
        state = getString(getColumnIndexOrThrow("state")).toPairingState(),
        offerInviteId = if (isNull(getColumnIndexOrThrow("offer_invite_id"))) null else getString(getColumnIndexOrThrow("offer_invite_id")),
        offerPayload = if (isNull(getColumnIndexOrThrow("offer_payload"))) null else getBlob(getColumnIndexOrThrow("offer_payload")),
    )

}
