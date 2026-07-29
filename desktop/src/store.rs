use crate::sql;
use anyhow::{Context, Result};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit},
};
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
use torchat_client_runtime::{ConversationState, ConversationSummary, MessageState};
use torchat_core::{Identity, relay::ContactCard};

#[derive(Clone, Debug)]
pub struct StoredMessage {
    pub id: String,
    pub peer: String,
    pub outgoing: bool,
    pub body: String,
    pub state: MessageState,
    pub created_at: i64,
    pub relay_payload: Option<String>,
    pub attempt_count: i64,
    pub last_attempt_at: Option<i64>,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_transport_error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct ReceivedEnvelope {
    pub sender_installation_id: String,
    pub message_id: String,
    pub ciphertext_hash: Vec<u8>,
    pub received_at: i64,
    pub receipt_state: String,
}

#[derive(Clone, Debug)]
pub struct DeliveryReceiptRecord {
    pub message_id: String,
    pub original_sender: String,
    pub state: String,
    pub attempt_count: i64,
    pub next_attempt_at: i64,
    pub created_at: i64,
    pub last_error: Option<String>,
}

pub struct LocalStore {
    connection: Connection,
    cipher: XChaCha20Poly1305,
}

fn migrate(connection: &Connection) -> Result<()> {
    let (_, migration_table) = sql::MIGRATIONS
        .first()
        .context("desktop migration list is empty")?;
    connection.execute_batch(migration_table)?;
    for (name, migration) in sql::MIGRATIONS.iter().skip(1) {
        let checksum = format!("{:x}", Sha256::digest(migration.as_bytes()));
        let applied: Option<String> = connection
            .query_row(sql::MIGRATION_LOOKUP, [name], |row| row.get(0))
            .optional()?;
        if let Some(applied) = applied {
            anyhow::ensure!(
                applied == checksum,
                "desktop migration checksum changed: {name}"
            );
            continue;
        }

        // Versions 002 and 003 were previously applied ad hoc by the store.
        // Inspect the schema before executing them so existing installations
        // are upgraded without hiding unrelated migration errors.
        let already_present = match *name {
            "002_messages_relay_payload.sql" => {
                has_column(connection, "messages", "relay_payload")?
            }
            "003_contacts_verification.sql" => has_column(connection, "contacts", "verification")?,
            _ => false,
        };
        if !already_present {
            connection.execute_batch(migration)?;
        }
        connection.execute(sql::MIGRATION_INSERT, params![name, checksum])?;
    }
    Ok(())
}

fn has_column(connection: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut statement = connection.prepare(sql::TABLE_COLUMNS)?;
    let columns = statement.query_map([table], |row| row.get::<_, String>(0))?;
    Ok(columns
        .collect::<rusqlite::Result<Vec<_>>>()?
        .iter()
        .any(|value| value == column))
}

impl LocalStore {
    pub fn open(path: &Path, identity: &Identity) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).context("create desktop state directory")?;
        }
        let connection = Connection::open(path).context("open desktop state database")?;
        connection.execute_batch(sql::CONNECTION_PRAGMAS)?;
        migrate(&connection)?;
        let mut hash = Sha256::new();
        hash.update(b"torchat-desktop-local-store-v1");
        hash.update(identity.private_key_bytes());
        let store = Self {
            connection,
            cipher: XChaCha20Poly1305::new(&hash.finalize()),
        };
        store.backfill_legacy_conversations()?;
        Ok(store)
    }

    pub fn put_contact(&self, card: &ContactCard, source: &str) -> Result<()> {
        card.validate().map_err(anyhow::Error::msg)?;
        self.connection.execute(
            sql::CONTACT_UPSERT,
            params![
                card.installation_id,
                card.public_key,
                card.fingerprint,
                card.nickname,
                source
            ],
        )?;
        Ok(())
    }

    pub fn contacts(&self) -> Result<Vec<ContactCard>> {
        let mut statement = self.connection.prepare(sql::CONTACTS_LIST)?;
        let values = statement
            .query_map([], |row| {
                Ok(ContactCard {
                    installation_id: row.get(0)?,
                    public_key: row.get(1)?,
                    fingerprint: row.get(2)?,
                    nickname: row.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(values)
    }

    pub fn verify_contact(&self, installation_id: &str) -> Result<()> {
        self.connection
            .execute(sql::CONTACT_VERIFY, [installation_id])?;
        Ok(())
    }

    pub fn contact_is_verified(&self, installation_id: &str) -> Result<bool> {
        let value: Option<String> = self
            .connection
            .query_row(sql::CONTACT_VERIFICATION, [installation_id], |row| {
                row.get(0)
            })
            .optional()?;
        Ok(value.as_deref() == Some("VERIFIED"))
    }

    pub fn mark_conversation_read(&self, peer: &str) -> Result<()> {
        self.connection
            .execute(sql::CONVERSATION_MARK_READ, [peer])?;
        Ok(())
    }

    pub fn put_runtime_conversation(&self, conversation: &ConversationSummary) -> Result<()> {
        let preview = self.encrypt(conversation.last_message_preview.as_bytes())?;
        self.connection.execute(
            sql::CONVERSATION_UPSERT,
            params![
                conversation.id,
                conversation.contact_installation_id,
                conversation.status.as_str(),
                preview,
                conversation.last_message_at,
                i64::from(conversation.unread_count),
            ],
        )?;
        Ok(())
    }

    pub fn runtime_conversations(&self) -> Result<Vec<ConversationSummary>> {
        let mut statement = self.connection.prepare(sql::CONVERSATIONS_LIST)?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<Vec<u8>>>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?;
        rows.map(|row| self.decode_runtime_conversation_row(row?))
            .collect()
    }

    #[allow(dead_code)]
    pub fn runtime_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<Option<ConversationSummary>> {
        self.connection
            .query_row(sql::CONVERSATION_GET, [conversation_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<Vec<u8>>>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })
            .optional()?
            .map(|row| self.decode_runtime_conversation_row(row))
            .transpose()
    }

    pub fn put_conversation_mls(&self, conversation_id: &str, snapshot: &[u8]) -> Result<()> {
        self.connection.execute(
            sql::CONVERSATION_MLS_UPSERT,
            params![conversation_id, snapshot],
        )?;
        Ok(())
    }

    pub fn conversation_mls(&self, conversation_id: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .connection
            .query_row(sql::CONVERSATION_MLS_GET, [conversation_id], |row| {
                row.get(0)
            })
            .optional()?)
    }

    pub fn delete_conversation_mls(&self, conversation_id: &str) -> Result<()> {
        self.connection
            .execute(sql::CONVERSATION_MLS_DELETE, [conversation_id])?;
        Ok(())
    }

    fn legacy_runtime_peers(&self) -> Result<Vec<String>> {
        let mut statement = self.connection.prepare(sql::CONVERSATIONS_LIST)?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn decode_runtime_conversation_row(
        &self,
        row: (String, String, String, Option<Vec<u8>>, i64, i64),
    ) -> Result<ConversationSummary> {
        let (
            id,
            contact_installation_id,
            status,
            last_message_preview,
            last_message_at,
            unread_count,
        ) = row;
        let preview = match last_message_preview {
            Some(value) => {
                String::from_utf8(self.decrypt(&value)?).context("message is not UTF-8")?
            }
            None => String::new(),
        };
        let status = ConversationState::try_from(status.as_str()).map_err(anyhow::Error::msg)?;
        Ok(ConversationSummary {
            id,
            contact_installation_id,
            status,
            last_message_preview: preview,
            last_message_at,
            unread_count: unread_count.max(0) as u32,
        })
    }

    pub fn backfill_legacy_conversations(&self) -> Result<()> {
        let peers = self.legacy_runtime_peers()?;
        for peer in peers {
            let snapshot = self.conversation_mls(&peer)?;
            let decrypted = snapshot
                .as_ref()
                .map(|value| self.decrypt(value))
                .transpose()?;
            let _status = if decrypted.as_ref().is_some_and(|value| !value.is_empty()) {
                ConversationState::Active
            } else {
                ConversationState::Pending
            };
            if decrypted.as_ref().is_some_and(|value| value.is_empty()) {
                self.delete_conversation_mls(&peer)?;
            } else {
                self.connection
                    .execute(sql::CONVERSATION_STATUS_PROMOTE_LEGACY, params![peer])?;
            }
        }
        Ok(())
    }

    pub fn put_secret(&self, key: &str, value: &[u8]) -> Result<()> {
        self.connection
            .execute(sql::SETTING_UPSERT, params![key, self.encrypt(value)?])?;
        Ok(())
    }

    pub fn secret(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let value: Option<Vec<u8>> = self
            .connection
            .query_row(sql::SETTING_GET, [key], |row| row.get(0))
            .optional()?;
        value.map(|value| self.decrypt(&value)).transpose()
    }

    pub fn put_message(&self, message: &StoredMessage) -> Result<()> {
        self.connection.execute(
            sql::MESSAGE_UPSERT,
            params![
                message.id,
                message.peer,
                message.outgoing,
                self.encrypt(message.body.as_bytes())?,
                message.state.as_str(),
                message.created_at,
                message
                    .relay_payload
                    .as_ref()
                    .map(|value| self.encrypt(value.as_bytes()))
                    .transpose()?,
                message.attempt_count,
                message.last_attempt_at,
                message.next_attempt_at,
                message.ack_deadline,
                message.last_transport_error,
            ],
        )?;
        Ok(())
    }

    pub fn persist_outbound_encryption(
        &mut self,
        message: &StoredMessage,
        conversation_id: &str,
        mls_snapshot: &[u8],
        conversation: &ConversationSummary,
    ) -> Result<()> {
        let encrypted_body = self.encrypt(message.body.as_bytes())?;
        let encrypted_relay_payload = message
            .relay_payload
            .as_ref()
            .map(|value| self.encrypt(value.as_bytes()))
            .transpose()?;
        let encrypted_preview = self.encrypt(conversation.last_message_preview.as_bytes())?;
        let transaction = self.connection.transaction()?;
        transaction.execute(
            sql::MESSAGE_UPSERT,
            params![
                message.id,
                message.peer,
                message.outgoing,
                encrypted_body,
                message.state.as_str(),
                message.created_at,
                encrypted_relay_payload,
                message.attempt_count,
                message.last_attempt_at,
                message.next_attempt_at,
                message.ack_deadline,
                message.last_transport_error,
            ],
        )?;
        transaction.execute(
            sql::CONVERSATION_MLS_UPSERT,
            params![conversation_id, mls_snapshot],
        )?;
        transaction.execute(
            sql::CONVERSATION_UPSERT,
            params![
                conversation.id,
                conversation.contact_installation_id,
                conversation.status.as_str(),
                encrypted_preview,
                conversation.last_message_at,
                i64::from(conversation.unread_count),
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn persist_inbound_application(
        &mut self,
        dedupe: &ReceivedEnvelope,
        message: &StoredMessage,
        conversation: &ConversationSummary,
        mls_snapshot: &[u8],
        receipt: &DeliveryReceiptRecord,
    ) -> Result<()> {
        let encrypted_body = self.encrypt(message.body.as_bytes())?;
        let encrypted_relay_payload = message
            .relay_payload
            .as_ref()
            .map(|value| self.encrypt(value.as_bytes()))
            .transpose()?;
        let encrypted_preview = self.encrypt(conversation.last_message_preview.as_bytes())?;
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT OR REPLACE INTO received_envelopes (sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                dedupe.sender_installation_id,
                dedupe.message_id,
                dedupe.ciphertext_hash,
                dedupe.received_at,
                dedupe.receipt_state,
            ],
        )?;
        transaction.execute(
            sql::MESSAGE_UPSERT,
            params![
                message.id,
                message.peer,
                message.outgoing,
                encrypted_body,
                message.state.as_str(),
                message.created_at,
                encrypted_relay_payload,
                message.attempt_count,
                message.last_attempt_at,
                message.next_attempt_at,
                message.ack_deadline,
                message.last_transport_error,
            ],
        )?;
        transaction.execute(
            sql::CONVERSATION_MLS_UPSERT,
            params![conversation.id, mls_snapshot],
        )?;
        transaction.execute(
            sql::CONVERSATION_UPSERT,
            params![
                conversation.id,
                conversation.contact_installation_id,
                conversation.status.as_str(),
                encrypted_preview,
                conversation.last_message_at,
                i64::from(conversation.unread_count),
            ],
        )?;
        transaction.execute(
            "INSERT OR REPLACE INTO delivery_receipts (message_id, original_sender, state, attempt_count, next_attempt_at, created_at, last_error) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                receipt.message_id,
                receipt.original_sender,
                receipt.state,
                receipt.attempt_count,
                receipt.next_attempt_at,
                receipt.created_at,
                receipt.last_error,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn consume_invite(&self, invite_id: &str) -> Result<bool> {
        let exists: Option<String> = self
            .connection
            .query_row(sql::INVITE_LOOKUP, [invite_id], |row| row.get(0))
            .optional()?;
        if exists.is_some() {
            return Ok(false);
        }
        self.connection.execute(sql::INVITE_INSERT, [invite_id])?;
        Ok(true)
    }

    pub fn messages(&self, peer: &str) -> Result<Vec<StoredMessage>> {
        let mut statement = self.connection.prepare(sql::MESSAGES_LIST)?;
        let rows = statement.query_map([peer], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<Vec<u8>>>(6)?,
                row.get::<_, i64>(7)?,
                row.get::<_, Option<i64>>(8)?,
                row.get::<_, i64>(9)?,
                row.get::<_, Option<i64>>(10)?,
                row.get::<_, Option<String>>(11)?,
            ))
        })?;
        rows.map(|row| {
            let (
                id,
                peer,
                outgoing,
                body,
                state,
                created_at,
                relay_payload,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            ) = row?;
            Ok(StoredMessage {
                id,
                peer,
                outgoing,
                body: String::from_utf8(self.decrypt(&body)?).context("message is not UTF-8")?,
                state: desktop_message_state_from_db(&state)?,
                created_at,
                relay_payload: relay_payload
                    .map(|value| self.decrypt(&value))
                    .transpose()?
                    .map(|value| String::from_utf8(value).context("relay payload is not UTF-8"))
                    .transpose()?,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            })
        })
        .collect()
    }

    pub fn message(&self, id: &str) -> Result<Option<StoredMessage>> {
        self.connection
            .query_row(sql::MESSAGE_GET, [id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, bool>(2)?,
                    row.get::<_, Vec<u8>>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Option<Vec<u8>>>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, Option<i64>>(10)?,
                    row.get::<_, Option<String>>(11)?,
                ))
            })
            .optional()?
            .map(
                |(
                    id,
                    peer,
                    outgoing,
                    body,
                    state,
                    created_at,
                    relay_payload,
                    attempt_count,
                    last_attempt_at,
                    next_attempt_at,
                    ack_deadline,
                    last_transport_error,
                )| {
                    Ok(StoredMessage {
                        id,
                        peer,
                        outgoing,
                        body: String::from_utf8(self.decrypt(&body)?)
                            .context("message is not UTF-8")?,
                        state: desktop_message_state_from_db(&state)?,
                        created_at,
                        relay_payload: relay_payload
                            .map(|value| self.decrypt(&value))
                            .transpose()?
                            .map(|value| {
                                String::from_utf8(value).context("relay payload is not UTF-8")
                            })
                            .transpose()?,
                        attempt_count,
                        last_attempt_at,
                        next_attempt_at,
                        ack_deadline,
                        last_transport_error,
                    })
                },
            )
            .transpose()
    }

    /// Returns outgoing messages which still need a relay attempt. `sending`
    /// is included so a process/reconnect interruption can resume the queue.
    pub fn pending_outgoing(&self, now_ms: i64) -> Result<Vec<StoredMessage>> {
        let mut statement = self.connection.prepare(sql::MESSAGES_PENDING)?;
        let rows = statement.query_map([now_ms], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<Vec<u8>>>(6)?,
                row.get::<_, i64>(7)?,
                row.get::<_, Option<i64>>(8)?,
                row.get::<_, i64>(9)?,
                row.get::<_, Option<i64>>(10)?,
                row.get::<_, Option<String>>(11)?,
            ))
        })?;
        rows.map(|row| {
            let (
                id,
                peer,
                outgoing,
                body,
                state,
                created_at,
                relay_payload,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            ) = row?;
            Ok(StoredMessage {
                id,
                peer,
                outgoing,
                body: String::from_utf8(self.decrypt(&body)?).context("message is not UTF-8")?,
                state: desktop_message_state_from_db(&state)?,
                created_at,
                relay_payload: relay_payload
                    .map(|value| self.decrypt(&value))
                    .transpose()?
                    .map(|value| String::from_utf8(value).context("relay payload is not UTF-8"))
                    .transpose()?,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            })
        })
        .collect()
    }

    fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let mut nonce = [0_u8; 24];
        rand::rng().fill_bytes(&mut nonce);
        let ciphertext = self
            .cipher
            .encrypt(XNonce::from_slice(&nonce), plaintext)
            .map_err(|_| anyhow::anyhow!("encrypt local state"))?;
        Ok([nonce.as_slice(), ciphertext.as_slice()].concat())
    }

    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        if ciphertext.len() < 24 {
            anyhow::bail!("truncated encrypted local state")
        }
        self.cipher
            .decrypt(XNonce::from_slice(&ciphertext[..24]), &ciphertext[24..])
            .map_err(|_| anyhow::anyhow!("decrypt local state"))
    }

    pub fn received_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> Result<Option<ReceivedEnvelope>> {
        self.connection
            .query_row(
                "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state FROM received_envelopes WHERE sender_installation_id = ?1 AND message_id = ?2",
                params![sender_installation_id, message_id],
                |row| {
                    Ok(ReceivedEnvelope {
                        sender_installation_id: row.get(0)?,
                        message_id: row.get(1)?,
                        ciphertext_hash: row.get(2)?,
                        received_at: row.get(3)?,
                        receipt_state: row.get(4)?,
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn put_received_envelope(&self, value: &ReceivedEnvelope) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO received_envelopes (sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                value.sender_installation_id,
                value.message_id,
                value.ciphertext_hash,
                value.received_at,
                value.receipt_state,
            ],
        )?;
        Ok(())
    }

    pub fn put_delivery_receipt(&self, value: &DeliveryReceiptRecord) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO delivery_receipts (message_id, original_sender, state, attempt_count, next_attempt_at, created_at, last_error) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                value.message_id,
                value.original_sender,
                value.state,
                value.attempt_count,
                value.next_attempt_at,
                value.created_at,
                value.last_error,
            ],
        )?;
        Ok(())
    }

    pub fn pending_delivery_receipts(&self, now_ms: i64) -> Result<Vec<DeliveryReceiptRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT message_id, original_sender, state, attempt_count, next_attempt_at, created_at, last_error FROM delivery_receipts WHERE UPPER(state) IN ('PENDING', 'SENT') AND next_attempt_at <= ?1 ORDER BY next_attempt_at, created_at, message_id",
        )?;
        let rows = statement.query_map([now_ms], |row| {
            Ok(DeliveryReceiptRecord {
                message_id: row.get(0)?,
                original_sender: row.get(1)?,
                state: row.get(2)?,
                attempt_count: row.get(3)?,
                next_attempt_at: row.get(4)?,
                created_at: row.get(5)?,
                last_error: row.get(6)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    pub fn pending_received_envelopes(&self) -> Result<Vec<ReceivedEnvelope>> {
        let mut statement = self.connection.prepare(
            "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state FROM received_envelopes WHERE UPPER(receipt_state) = 'PENDING' ORDER BY received_at, message_id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(ReceivedEnvelope {
                sender_installation_id: row.get(0)?,
                message_id: row.get(1)?,
                ciphertext_hash: row.get(2)?,
                received_at: row.get(3)?,
                receipt_state: row.get(4)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    pub fn claim_outgoing_retry(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        ack_deadline: Option<i64>,
        last_transport_error: Option<&str>,
    ) -> Result<bool> {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_millis() as i64)
            .unwrap_or_default();
        let changed = self.connection.execute(
            "UPDATE messages SET state = 'SENDING', attempt_count = attempt_count + 1, last_attempt_at = ?1, next_attempt_at = ?2, ack_deadline = ?3, last_transport_error = ?4 WHERE id = ?5 AND outgoing = 1 AND UPPER(state) IN ('QUEUED', 'SENT') AND next_attempt_at <= ?6",
            params![now_ms, next_attempt_at, ack_deadline, last_transport_error, message_id, now_ms],
        )?;
        Ok(changed > 0)
    }

    pub fn claim_receipt_retry(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> Result<bool> {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_millis() as i64)
            .unwrap_or_default();
        let changed = self.connection.execute(
            "UPDATE delivery_receipts SET state = 'SENT', attempt_count = attempt_count + 1, next_attempt_at = ?1, last_error = ?2 WHERE message_id = ?3 AND UPPER(state) IN ('PENDING', 'SENT') AND next_attempt_at <= ?4",
            params![next_attempt_at, last_error, message_id, now_ms],
        )?;
        Ok(changed > 0)
    }

    pub fn accelerate_retry_after_ready(&self, now_ms: i64) -> Result<()> {
        self.connection.execute(
            "UPDATE messages SET next_attempt_at = ?1 WHERE outgoing = 1 AND UPPER(state) IN ('QUEUED', 'SENDING', 'SENT') AND next_attempt_at > ?1",
            params![now_ms],
        )?;
        self.connection.execute(
            "UPDATE delivery_receipts SET next_attempt_at = ?1 WHERE UPPER(state) IN ('PENDING', 'SENT') AND next_attempt_at > ?1",
            params![now_ms],
        )?;
        Ok(())
    }

    pub fn requeue_sending_after_disconnect(&self, now_ms: i64) -> Result<()> {
        self.connection.execute(
            "UPDATE messages SET state = 'QUEUED', next_attempt_at = ?1, ack_deadline = NULL WHERE outgoing = 1 AND UPPER(state) = 'SENDING'",
            params![now_ms],
        )?;
        Ok(())
    }
}

fn desktop_message_state_from_db(value: &str) -> Result<MessageState> {
    match value.trim().to_ascii_uppercase().as_str() {
        "QUEUED" => Ok(MessageState::Queued),
        "SENDING" => Ok(MessageState::Sending),
        "SENT" => Ok(MessageState::Sent),
        "DELIVERED" => Ok(MessageState::Delivered),
        "FAILED" => Ok(MessageState::Failed),
        state => anyhow::bail!("unknown desktop message state: {state}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn encrypted_state_round_trip() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();
        store
            .put_message(&StoredMessage {
                id: "one".into(),
                peer: "bob".into(),
                outgoing: true,
                body: "sekret".into(),
                state: MessageState::Sent,
                created_at: 1,
                relay_payload: None,
                attempt_count: 0,
                last_attempt_at: None,
                next_attempt_at: 0,
                ack_deadline: None,
                last_transport_error: None,
            })
            .unwrap();
        assert_eq!(store.messages("bob").unwrap()[0].body, "sekret");
        drop(store);
        let bytes = std::fs::read(&path).unwrap();
        assert!(!bytes.windows(6).any(|part| part == b"sekret"));
        cleanup_store(&path);
    }

    #[test]
    fn canonical_conversation_round_trips_exact_fields() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();

        let summary = ConversationSummary {
            id: "conversation-1".into(),
            contact_installation_id: "peer-1".into(),
            status: ConversationState::Offline,
            last_message_preview: "hello".into(),
            last_message_at: 42,
            unread_count: 7,
        };

        store.put_runtime_conversation(&summary).unwrap();

        assert_eq!(
            store.runtime_conversation("conversation-1").unwrap(),
            Some(summary.clone())
        );
        assert_eq!(store.runtime_conversations().unwrap(), vec![summary]);

        drop(store);
        let bytes = std::fs::read(&path).unwrap();
        assert!(!bytes.windows(b"hello".len()).any(|value| value == b"hello"));
        cleanup_store(&path);
    }

    #[test]
    fn canonical_update_preserves_mls_snapshot() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();

        let mut summary = ConversationSummary {
            id: "conversation-1".into(),
            contact_installation_id: "peer-1".into(),
            status: ConversationState::Verifying,
            last_message_preview: "verify".into(),
            last_message_at: 1,
            unread_count: 0,
        };

        store.put_runtime_conversation(&summary).unwrap();
        store
            .put_conversation_mls(&summary.id, b"mls-snapshot")
            .unwrap();

        summary.status = ConversationState::Active;
        summary.last_message_preview = "ready".into();
        summary.last_message_at = 2;
        store.put_runtime_conversation(&summary).unwrap();

        assert_eq!(
            store.conversation_mls(&summary.id).unwrap().as_deref(),
            Some(b"mls-snapshot".as_slice())
        );
        cleanup_store(&path);
    }

    #[test]
    fn mls_requires_existing_runtime_conversation() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();
        let error = store
            .put_conversation_mls("missing", b"snapshot")
            .unwrap_err();
        assert!(error.to_string().to_lowercase().contains("foreign key"));
        cleanup_store(&path);
    }

    #[test]
    fn outbound_persist_is_atomic_for_message_and_conversation_snapshot() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let mut store = LocalStore::open(&path, &identity).unwrap();

        let conversation = ConversationSummary {
            id: "conversation-1".into(),
            contact_installation_id: "peer-1".into(),
            status: ConversationState::Active,
            last_message_preview: "preview".into(),
            last_message_at: 7,
            unread_count: 0,
        };
        store.put_runtime_conversation(&conversation).unwrap();

        let message = StoredMessage {
            id: "message-1".into(),
            peer: "peer-1".into(),
            outgoing: true,
            body: "hello".into(),
            state: MessageState::Sent,
            created_at: 42,
            relay_payload: Some("ciphertext".into()),
            attempt_count: 1,
            last_attempt_at: Some(41),
            next_attempt_at: 99,
            ack_deadline: Some(123),
            last_transport_error: Some("none".into()),
        };

        store
            .persist_outbound_encryption(&message, &conversation.id, b"mls-snapshot", &conversation)
            .unwrap();

        let stored = store.message("message-1").unwrap().unwrap();
        assert_eq!(stored.body, "hello");
        assert_eq!(stored.relay_payload, Some("ciphertext".into()));
        assert_eq!(stored.attempt_count, 1);
        assert_eq!(
            store.conversation_mls(&conversation.id).unwrap().as_deref(),
            Some(b"mls-snapshot".as_slice())
        );
        assert_eq!(
            store
                .runtime_conversation(&conversation.id)
                .unwrap()
                .unwrap()
                .last_message_preview,
            "preview"
        );
        cleanup_store(&path);
    }

    #[test]
    fn inbound_persist_writes_dedupe_message_and_receipt_together() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let mut store = LocalStore::open(&path, &identity).unwrap();

        let conversation = ConversationSummary {
            id: "conversation-1".into(),
            contact_installation_id: "peer-1".into(),
            status: ConversationState::Active,
            last_message_preview: "preview".into(),
            last_message_at: 7,
            unread_count: 1,
        };
        store.put_runtime_conversation(&conversation).unwrap();

        let dedupe = ReceivedEnvelope {
            sender_installation_id: "peer-1".into(),
            message_id: "message-1".into(),
            ciphertext_hash: vec![1, 2, 3],
            received_at: 42,
            receipt_state: "PENDING".into(),
        };
        let message = StoredMessage {
            id: "message-1".into(),
            peer: "peer-1".into(),
            outgoing: false,
            body: "hello".into(),
            state: MessageState::Delivered,
            created_at: 42,
            relay_payload: None,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        };
        let receipt = DeliveryReceiptRecord {
            message_id: "message-1".into(),
            original_sender: "peer-1".into(),
            state: "PENDING".into(),
            attempt_count: 0,
            next_attempt_at: 0,
            created_at: 42,
            last_error: None,
        };

        store
            .persist_inbound_application(
                &dedupe,
                &message,
                &conversation,
                b"mls-snapshot",
                &receipt,
            )
            .unwrap();

        assert_eq!(
            store
                .received_envelope("peer-1", "message-1")
                .unwrap()
                .unwrap()
                .receipt_state,
            "PENDING"
        );
        assert_eq!(store.message("message-1").unwrap().unwrap().body, "hello");
        assert_eq!(store.pending_received_envelopes().unwrap().len(), 1);
        assert_eq!(store.pending_delivery_receipts(0).unwrap().len(), 1);
        cleanup_store(&path);
    }

    #[test]
    fn retry_claims_are_atomic_and_update_backoff_columns() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();

        store
            .put_message(&StoredMessage {
                id: "message-1".into(),
                peer: "peer-1".into(),
                outgoing: true,
                body: "hello".into(),
                state: MessageState::Queued,
                created_at: 42,
                relay_payload: Some("ciphertext".into()),
                attempt_count: 0,
                last_attempt_at: None,
                next_attempt_at: 0,
                ack_deadline: None,
                last_transport_error: None,
            })
            .unwrap();
        store
            .put_delivery_receipt(&DeliveryReceiptRecord {
                message_id: "receipt-1".into(),
                original_sender: "peer-1".into(),
                state: "PENDING".into(),
                attempt_count: 0,
                next_attempt_at: 0,
                created_at: 42,
                last_error: None,
            })
            .unwrap();

        assert!(
            store
                .claim_outgoing_retry("message-1", 200, Some(300), Some("oops"))
                .unwrap()
        );
        let message = store.message("message-1").unwrap().unwrap();
        assert_eq!(message.state, MessageState::Sending);
        assert_eq!(message.attempt_count, 1);
        assert_eq!(message.next_attempt_at, 200);
        assert_eq!(message.ack_deadline, Some(300));
        assert_eq!(message.last_transport_error.as_deref(), Some("oops"));

        assert!(
            store
                .claim_receipt_retry("receipt-1", 400, Some("retry"))
                .unwrap()
        );
        let receipt = store.pending_delivery_receipts(400).unwrap();
        assert_eq!(receipt.len(), 1);
        assert_eq!(receipt[0].attempt_count, 1);
        assert_eq!(receipt[0].next_attempt_at, 400);
        assert_eq!(receipt[0].last_error.as_deref(), Some("retry"));
        cleanup_store(&path);
    }

    #[test]
    fn pending_outgoing_includes_sent_only_when_retry_is_due() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();

        for (id, state, next_attempt_at) in [
            ("queued-due", MessageState::Queued, 10),
            ("sending-due", MessageState::Sending, 20),
            ("sent-due", MessageState::Sent, 30),
            ("sent-later", MessageState::Sent, 999),
            ("delivered-due", MessageState::Delivered, 0),
        ] {
            store
                .put_message(&StoredMessage {
                    id: id.into(),
                    peer: "peer-1".into(),
                    outgoing: true,
                    body: id.into(),
                    state,
                    created_at: next_attempt_at,
                    relay_payload: Some(format!("payload-{id}")),
                    attempt_count: 0,
                    last_attempt_at: None,
                    next_attempt_at,
                    ack_deadline: None,
                    last_transport_error: None,
                })
                .unwrap();
        }

        let pending = store
            .pending_outgoing(100)
            .unwrap()
            .into_iter()
            .map(|message| message.id)
            .collect::<Vec<_>>();

        assert_eq!(pending, vec!["queued-due", "sending-due", "sent-due"]);
        cleanup_store(&path);
    }

    #[test]
    fn migration_004_preserves_legacy_conversation_data() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let expected_mls =
            create_legacy_v003_database(&path, &identity, b"legacy-mls", "legacy preview", 9, 3);
        let store = LocalStore::open(&path, &identity).unwrap();
        let summary = store.runtime_conversation("peer-1").unwrap().unwrap();
        assert_eq!(summary.id, "peer-1");
        assert_eq!(summary.contact_installation_id, "peer-1");
        assert_eq!(summary.status, ConversationState::Active);
        assert_eq!(summary.last_message_preview, "legacy preview");
        assert_eq!(summary.last_message_at, 9);
        assert_eq!(summary.unread_count, 3);
        assert_eq!(
            store.conversation_mls("peer-1").unwrap().as_deref(),
            Some(expected_mls.as_slice())
        );
        cleanup_store(&path);
    }

    #[test]
    fn migration_004_removes_empty_legacy_mls_placeholder() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        create_legacy_v003_database(&path, &identity, b"", "legacy preview", 9, 3);
        let store = LocalStore::open(&path, &identity).unwrap();
        let summary = store.runtime_conversation("peer-1").unwrap().unwrap();
        assert_eq!(summary.status, ConversationState::Pending);
        assert_eq!(store.conversation_mls("peer-1").unwrap(), None);
        cleanup_store(&path);
    }

    fn create_legacy_v003_database(
        path: &Path,
        identity: &Identity,
        snapshot: &[u8],
        preview: &str,
        created_at: i64,
        unread_count: i64,
    ) -> Vec<u8> {
        let connection = Connection::open(path).unwrap();
        connection.execute_batch(sql::MIGRATIONS[0].1).unwrap();
        connection.execute_batch(sql::MIGRATIONS[1].1).unwrap();
        let mut hash = Sha256::new();
        hash.update(b"torchat-desktop-local-store-v1");
        hash.update(identity.private_key_bytes());
        let legacy = LocalStore {
            connection,
            cipher: XChaCha20Poly1305::new(&hash.finalize()),
        };
        let encrypted_snapshot = legacy.encrypt(snapshot).unwrap();
        legacy
            .connection
            .execute(
                sql::LEGACY_CONVERSATION_INSERT,
                params![
                    "peer-1",
                    encrypted_snapshot.clone(),
                    unread_count,
                    created_at
                ],
            )
            .unwrap();
        legacy
            .connection
            .execute(
                sql::LEGACY_MESSAGE_INSERT,
                params![
                    "message-1",
                    "peer-1",
                    false,
                    legacy.encrypt(preview.as_bytes()).unwrap(),
                    "DELIVERED",
                    created_at
                ],
            )
            .unwrap();
        encrypted_snapshot
    }

    fn cleanup_store(path: &Path) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(format!("{}-wal", path.display()));
        let _ = std::fs::remove_file(format!("{}-shm", path.display()));
    }
}
