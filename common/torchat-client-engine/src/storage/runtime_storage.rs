use rusqlite::{OptionalExtension, Transaction, params};
use torchat_client_runtime::{
    ChatMessage, ContactRecord, ConversationState, ConversationSummary, InviteCode, InviteState,
    MessageState, PairingItem, ReceiptSendEffect, RuntimeError, RuntimeIdentity, RuntimeProfile,
    RuntimeResult, RuntimeStorage, VerificationState,
};

use super::{
    SqliteTransaction,
    sqlite::{DeliveryReceiptRecord, PendingWelcomeRecord, ReceivedEnvelopeRecord},
};

pub struct SqliteRuntimeStorage<'db> {
    transaction: Option<SqliteTransaction<'db>>,
}

impl<'db> SqliteRuntimeStorage<'db> {
    pub fn new(transaction: SqliteTransaction<'db>) -> Self {
        Self {
            transaction: Some(transaction),
        }
    }

    pub fn commit(&mut self) -> RuntimeResult<()> {
        self.transaction
            .take()
            .expect("sqlite runtime storage transaction must exist for commit")
            .commit()
            .map_err(storage_engine_error)?;
        Ok(())
    }

    pub fn rollback(&mut self) -> RuntimeResult<()> {
        self.transaction
            .take()
            .expect("sqlite runtime storage transaction must exist for rollback")
            .rollback()
            .map_err(storage_engine_error)?;
        Ok(())
    }

    pub fn has_table_column(&self, table: &str, column: &str) -> Result<bool, crate::EngineError> {
        let mut statement = self
            .tx()
            .prepare(super::sqlite::TABLE_COLUMNS)
            .map_err(engine_storage_error)?;
        let columns = statement
            .query_map([table], |row| row.get::<_, String>("name"))
            .map_err(engine_storage_error)?;
        let names = columns
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(engine_storage_error)?;
        Ok(names.iter().any(|name| name == column))
    }

    pub fn put_identity(&mut self, identity: RuntimeIdentity) -> RuntimeResult<()> {
        self.put_setting_json(SETTING_IDENTITY, &identity)
    }

    pub fn ensure_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        if self.profile()?.is_none() {
            self.put_profile(profile)?;
        }
        Ok(())
    }

    fn tx(&self) -> &Transaction<'db> {
        self.transaction
            .as_ref()
            .expect("sqlite runtime storage transaction must exist while active")
            .as_ref()
    }

    fn get_setting_json<T: serde::de::DeserializeOwned>(
        &self,
        key: &'static str,
    ) -> RuntimeResult<Option<T>> {
        let blob: Option<Vec<u8>> = self
            .tx()
            .query_row("SELECT value FROM settings WHERE key = ?1;", [key], |row| {
                row.get("value")
            })
            .optional()
            .map_err(storage_error)?;
        blob.map(|value| serde_json::from_slice(&value).map_err(storage_error_json))
            .transpose()
    }

    fn put_setting_json<T: serde::Serialize>(
        &self,
        key: &'static str,
        value: &T,
    ) -> RuntimeResult<()> {
        let payload = serde_json::to_vec(value).map_err(storage_error_json)?;
        self.tx()
            .execute(
                "INSERT INTO settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                params![key, payload],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn decode_verification(value: String) -> RuntimeResult<VerificationState> {
        match value.trim().to_ascii_uppercase().as_str() {
            "VERIFIED" => Ok(VerificationState::Verified),
            "UNVERIFIED" => Ok(VerificationState::Unverified),
            other => Err(RuntimeError::Storage(format!(
                "unknown verification state: {other}"
            ))),
        }
    }

    fn decode_conversation_state(value: String) -> RuntimeResult<ConversationState> {
        ConversationState::try_from(value.as_str()).map_err(RuntimeError::Storage)
    }

    fn decode_message_state(value: String) -> RuntimeResult<MessageState> {
        match value.trim().to_ascii_uppercase().as_str() {
            "QUEUED" => Ok(MessageState::Queued),
            "SENDING" => Ok(MessageState::Sending),
            "SENT" => Ok(MessageState::Sent),
            "DELIVERED" => Ok(MessageState::Delivered),
            "READ" => Ok(MessageState::Read),
            "FAILED" => Ok(MessageState::Failed),
            other => Err(RuntimeError::Storage(format!(
                "unknown message state: {other}"
            ))),
        }
    }

    fn decode_invite_state(value: String) -> RuntimeResult<InviteState> {
        match value.trim().to_ascii_uppercase().as_str() {
            "PENDING" => Ok(InviteState::Pending),
            "ACCEPTED" => Ok(InviteState::Accepted),
            "REJECTED" => Ok(InviteState::Rejected),
            "COMPLETED" => Ok(InviteState::Completed),
            "EXPIRED" => Ok(InviteState::Expired),
            "ARCHIVED" => Ok(InviteState::Archived),
            "CANCELLED" => Ok(InviteState::Cancelled),
            other => Err(RuntimeError::Storage(format!(
                "unknown invite state: {other}"
            ))),
        }
    }

    /// Persists the MLS member inbox inside the same SQL transaction as the
    /// runtime mutation that consumed it.
    pub fn put_mls_inbox_snapshot(&mut self, snapshot: &[u8]) -> RuntimeResult<()> {
        self.put_setting_blob("mls_inbox_snapshot_v1", snapshot)
    }

    /// Persists a direct-conversation MLS snapshot in the active runtime
    /// transaction. Engine-owned cryptographic state must never be committed
    /// separately from the message/contact/conversation rows it protects.
    pub fn put_conversation_mls_snapshot(
        &mut self,
        conversation_id: &str,
        snapshot: &[u8],
    ) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO conversation_mls (conversation_id, snapshot, updated_at)
                 VALUES (?1, ?2, unixepoch())
                 ON CONFLICT(conversation_id) DO UPDATE SET
                    snapshot = excluded.snapshot,
                    updated_at = unixepoch();",
                params![conversation_id, snapshot],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn put_pending_welcome(&mut self, record: &PendingWelcomeRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO pending_welcomes (
                    invite_id, recipient_installation_id, payload, expires_at,
                    attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    payload = excluded.payload,
                    expires_at = excluded.expires_at,
                    attempt_count = excluded.attempt_count,
                    next_attempt_at = excluded.next_attempt_at,
                    last_error = excluded.last_error;",
                params![
                    record.invite_id,
                    record.recipient_installation_id,
                    record.payload,
                    record.expires_at,
                    i64::from(record.attempt_count),
                    record.next_attempt_at,
                    record.last_error,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn remove_pending_welcome(&mut self, invite_id: &str) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "DELETE FROM pending_welcomes WHERE invite_id = ?1;",
                [invite_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn consume_invite(&mut self, invite_id: &str) -> RuntimeResult<bool> {
        let inserted = self
            .tx()
            .execute(
                "INSERT OR IGNORE INTO used_invites (invite_id, used_at)
                 VALUES (?1, unixepoch());",
                [invite_id],
            )
            .map_err(storage_error)?;
        Ok(inserted > 0)
    }

    pub fn put_received_envelope(&mut self, value: &ReceivedEnvelopeRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO received_envelopes (
                    sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 ) VALUES (?1, ?2, ?3, ?4, ?5);",
                params![
                    value.sender_installation_id,
                    value.message_id,
                    value.ciphertext_hash,
                    value.received_at,
                    value.receipt_state,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn put_delivery_receipt(&mut self, value: &DeliveryReceiptRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO delivery_receipts (
                    envelope_id, message_id, conversation_id, original_sender, received_at,
                    relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);",
                params![
                    value.envelope_id,
                    value.message_id,
                    value.conversation_id,
                    value.original_sender,
                    value.received_at,
                    value.relay_payload,
                    value.state,
                    i64::from(value.attempt_count),
                    value.next_attempt_at,
                    value.last_error,
                    value.created_at,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn persist_outbound_encryption(
        &mut self,
        message_id: &str,
        relay_payload: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
    ) -> RuntimeResult<()> {
        use sha2::Digest as _;
        let ciphertext_hash = sha2::Sha256::digest(relay_payload).to_vec();
        let changed = self
            .tx()
            .execute(
                "UPDATE messages
                 SET relay_payload = ?2, ciphertext_hash = ?3
                 WHERE id = ?1;",
                params![message_id, relay_payload, ciphertext_hash],
            )
            .map_err(storage_error)?;
        if changed != 1 {
            return Err(RuntimeError::Storage(format!(
                "outgoing message {message_id} was not present in the active transaction"
            )));
        }
        self.put_conversation_mls_snapshot(conversation_id, snapshot)
    }

    pub fn claim_outgoing_attempt(
        &mut self,
        message_id: &str,
        next_attempt_at: i64,
        ack_deadline: Option<i64>,
        last_transport_error: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<bool> {
        let changed = self
            .tx()
            .execute(
                "UPDATE messages
                 SET attempt_count = attempt_count + 1,
                     last_attempt_at = ?1,
                     next_attempt_at = ?2,
                     ack_deadline = ?3,
                     last_transport_error = ?4
                 WHERE id = ?5
                   AND outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'QUEUED')
                   AND next_attempt_at <= ?1;",
                params![
                    now_ms,
                    next_attempt_at,
                    ack_deadline,
                    last_transport_error,
                    message_id,
                ],
            )
            .map_err(storage_error)?;
        Ok(changed > 0)
    }

    fn put_setting_blob(&self, key: &str, value: &[u8]) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO settings (key, value)
                 VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                params![key, value],
            )
            .map_err(storage_error)?;
        Ok(())
    }
}

impl RuntimeStorage for SqliteRuntimeStorage<'_> {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        self.get_setting_json(SETTING_IDENTITY)
    }

    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        self.get_setting_json(SETTING_PROFILE)
    }

    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        self.put_setting_json(SETTING_PROFILE, &profile)
    }

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>> {
        self.get_setting_json(SETTING_PAIRING_CODE)
    }

    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()> {
        self.put_setting_json(SETTING_PAIRING_CODE, &code)
    }

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT pairing_id, sender_installation_id, sender_nickname,
                        sender_public_key, sender_fingerprint, capability,
                        expires_at, state, offer_invite_id, offer_payload
                 FROM pairing_inbox
                 ORDER BY updated_at DESC, pairing_id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>("pairing_id")?,
                    row.get::<_, String>("sender_installation_id")?,
                    row.get::<_, String>("sender_nickname")?,
                    row.get::<_, String>("sender_public_key")?,
                    row.get::<_, String>("sender_fingerprint")?,
                    row.get::<_, String>("capability")?,
                    row.get::<_, i64>("expires_at")?,
                    row.get::<_, String>("state")?,
                    row.get::<_, Option<String>>("offer_invite_id")?,
                    row.get::<_, Option<Vec<u8>>>("offer_payload")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (
                pairing_id,
                sender_installation_id,
                sender_nickname,
                sender_public_key,
                sender_fingerprint,
                capability,
                expires_at,
                state,
                offer_invite_id,
                offer_payload,
            ) = row.map_err(storage_error)?;
            Ok(finalize_pairing_item(PairingItem {
                pairing_id,
                sender: Some(ContactRecord {
                    installation_id: sender_installation_id,
                    nickname: sender_nickname,
                    public_key: sender_public_key,
                    fingerprint: sender_fingerprint,
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    verification: VerificationState::Unverified,
                    dev: None,
                }),
                capability: Some(capability),
                expires_at,
                state: Self::decode_invite_state(state)?,
                received: true,
                available_actions: Vec::new(),
                offer_invite_id,
                offer_payload: offer_payload
                    .map(|value| String::from_utf8_lossy(&value).into_owned()),
            }))
        })
        .collect()
    }

    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        let sender = item
            .sender
            .ok_or_else(|| RuntimeError::Storage("pairing inbox item missing sender".to_owned()))?;
        let capability = item.capability.ok_or_else(|| {
            RuntimeError::Storage("pairing inbox item missing capability".to_owned())
        })?;
        self.tx()
            .execute(
                "INSERT INTO pairing_inbox (
                    pairing_id, sender_installation_id, sender_nickname,
                    sender_public_key, sender_fingerprint, capability,
                    expires_at, state, offer_invite_id, offer_payload,
                    attempt_count, next_attempt_at, last_error, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 0, 0, NULL, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    sender_installation_id = excluded.sender_installation_id,
                    sender_nickname = excluded.sender_nickname,
                    sender_public_key = excluded.sender_public_key,
                    sender_fingerprint = excluded.sender_fingerprint,
                    capability = excluded.capability,
                    expires_at = excluded.expires_at,
                    state = excluded.state,
                    offer_invite_id = excluded.offer_invite_id,
                    offer_payload = excluded.offer_payload,
                    attempt_count = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN 0
                        ELSE pairing_inbox.attempt_count
                    END,
                    next_attempt_at = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN 0
                        ELSE pairing_inbox.next_attempt_at
                    END,
                    last_error = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN NULL
                        ELSE pairing_inbox.last_error
                    END,
                    updated_at = unixepoch();",
                params![
                    item.pairing_id,
                    sender.installation_id,
                    sender.nickname,
                    sender.public_key,
                    sender.fingerprint,
                    capability,
                    item.expires_at,
                    invite_state_str(item.state),
                    item.offer_invite_id,
                    item.offer_payload.map(|value| value.into_bytes()),
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT pairing_id, recipient_installation_id, capability, payload,
                        expires_at, state
                 FROM pairing_outbox
                 ORDER BY updated_at DESC, pairing_id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>("pairing_id")?,
                    row.get::<_, Option<String>>("recipient_installation_id")?,
                    row.get::<_, Option<String>>("capability")?,
                    row.get::<_, Option<Vec<u8>>>("payload")?,
                    row.get::<_, i64>("expires_at")?,
                    row.get::<_, String>("state")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (pairing_id, recipient_installation_id, capability, payload, expires_at, state) =
                row.map_err(storage_error)?;
            Ok(finalize_pairing_item(PairingItem {
                pairing_id,
                sender: recipient_installation_id.map(|installation_id| ContactRecord {
                    nickname: installation_id.clone(),
                    public_key: String::new(),
                    fingerprint: String::new(),
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    installation_id,
                    verification: VerificationState::Unverified,
                    dev: None,
                }),
                capability,
                expires_at,
                state: Self::decode_invite_state(state)?,
                received: false,
                available_actions: Vec::new(),
                offer_invite_id: None,
                offer_payload: payload.map(|value| String::from_utf8_lossy(&value).into_owned()),
            }))
        })
        .collect()
    }

    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO pairing_outbox (
                    pairing_id, recipient_installation_id, capability, payload,
                    expires_at, state, attempt_count, next_attempt_at, last_error,
                    created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, 0, 0, NULL, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    capability = excluded.capability,
                    payload = excluded.payload,
                    expires_at = excluded.expires_at,
                    state = excluded.state,
                    updated_at = unixepoch();",
                params![
                    item.pairing_id,
                    item.sender.map(|contact| contact.installation_id),
                    item.capability,
                    item.offer_payload.map(|value| value.into_bytes()),
                    item.expires_at,
                    invite_state_str(item.state),
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT installation_id, nickname, public_key, fingerprint, verification,
                        local_alias, muted, blocked
                 FROM contacts
                 ORDER BY updated_at DESC, installation_id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>("installation_id")?,
                    row.get::<_, String>("nickname")?,
                    row.get::<_, String>("public_key")?,
                    row.get::<_, String>("fingerprint")?,
                    row.get::<_, String>("verification")?,
                    row.get::<_, Option<String>>("local_alias")?,
                    row.get::<_, i64>("muted")?,
                    row.get::<_, i64>("blocked")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (
                installation_id,
                nickname,
                public_key,
                fingerprint,
                verification,
                local_alias,
                muted,
                blocked,
            ) = row.map_err(storage_error)?;
            Ok(ContactRecord {
                installation_id,
                nickname,
                public_key,
                fingerprint,
                local_alias,
                muted: muted != 0,
                blocked: blocked != 0,
                verification: Self::decode_verification(verification)?,
                dev: None,
            })
        })
        .collect()
    }

    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint, key_package,
                    verification, source, local_alias, muted, blocked, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, NULL, ?5, 'runtime', ?6, ?7, ?8, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(installation_id) DO UPDATE SET
                    nickname = excluded.nickname,
                    public_key = excluded.public_key,
                    fingerprint = excluded.fingerprint,
                    verification = excluded.verification,
                    local_alias = excluded.local_alias,
                    muted = excluded.muted,
                    blocked = excluded.blocked,
                    updated_at = unixepoch();",
                params![
                    contact.installation_id,
                    contact.nickname,
                    contact.public_key,
                    contact.fingerprint,
                    verification_state_str(contact.verification),
                    contact.local_alias,
                    if contact.muted { 1 } else { 0 },
                    if contact.blocked { 1 } else { 0 },
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT id, contact_installation_id, state,
                        COALESCE(last_message_preview, '') AS last_message_preview,
                        COALESCE(last_message_at, 0) AS last_message_at,
                        unread_count
                 FROM conversations
                 ORDER BY COALESCE(last_message_at, 0) DESC, id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>("id")?,
                    row.get::<_, String>("contact_installation_id")?,
                    row.get::<_, String>("state")?,
                    row.get::<_, String>("last_message_preview")?,
                    row.get::<_, i64>("last_message_at")?,
                    row.get::<_, i64>("unread_count")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (
                id,
                contact_installation_id,
                state,
                last_message_preview,
                last_message_at,
                unread_count,
            ) = row.map_err(storage_error)?;
            Ok(ConversationSummary {
                id,
                contact_installation_id,
                status: Self::decode_conversation_state(state)?,
                last_message_preview,
                last_message_at,
                unread_count: unread_count as u32,
            })
        })
        .collect()
    }

    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count,
                    last_message_preview, last_message_at, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(id) DO UPDATE SET
                    contact_installation_id = excluded.contact_installation_id,
                    state = excluded.state,
                    unread_count = excluded.unread_count,
                    last_message_preview = excluded.last_message_preview,
                    last_message_at = excluded.last_message_at,
                    updated_at = unixepoch();",
                params![
                    conversation.id,
                    conversation.contact_installation_id,
                    conversation.status.as_str(),
                    i64::from(conversation.unread_count),
                    conversation.last_message_preview,
                    conversation.last_message_at,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "UPDATE conversations
                 SET unread_count = 0, updated_at = unixepoch()
                 WHERE id = ?1;",
                [conversation_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                        attempt_count, last_attempt_at, next_attempt_at,
                        ack_deadline, last_transport_error
                 FROM messages
                 WHERE conversation_id = ?1
                 ORDER BY created_at ASC, id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([conversation_id], |row| {
                Ok((
                    row.get::<_, String>("id")?,
                    row.get::<_, String>("conversation_id")?,
                    row.get::<_, i64>("outgoing")?,
                    row.get::<_, String>("body")?,
                    row.get::<_, Option<String>>("reply_to_json")?,
                    row.get::<_, String>("state")?,
                    row.get::<_, i64>("created_at")?,
                    row.get::<_, i64>("attempt_count")?,
                    row.get::<_, Option<i64>>("last_attempt_at")?,
                    row.get::<_, i64>("next_attempt_at")?,
                    row.get::<_, Option<i64>>("ack_deadline")?,
                    row.get::<_, Option<String>>("last_transport_error")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (
                id,
                conversation_id,
                outgoing,
                body,
                reply_to_json,
                state,
                created_at,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            ) = row.map_err(storage_error)?;
            Ok(ChatMessage {
                id,
                conversation_id,
                outgoing: outgoing != 0,
                body,
                reply_to: decode_reply(reply_to_json)?,
                state: Self::decode_message_state(state)?,
                created_at,
                attempt_count: attempt_count as u32,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            })
        })
        .collect()
    }

    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()> {
        let existing = self
            .tx()
            .query_row(
                "SELECT relay_payload, ciphertext_hash
                 FROM messages
                 WHERE id = ?1;",
                [message.id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, Option<Vec<u8>>>("relay_payload")?,
                        row.get::<_, Option<Vec<u8>>>("ciphertext_hash")?,
                    ))
                },
            )
            .optional()
            .map_err(storage_error)?;
        let (relay_payload, ciphertext_hash) = existing.unwrap_or((None, None));
        self.tx()
            .execute(
                "INSERT INTO messages (
                    id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                    relay_payload, ciphertext_hash, attempt_count, last_attempt_at,
                    next_attempt_at, ack_deadline, last_transport_error
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14
                 )
                 ON CONFLICT(id) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    outgoing = excluded.outgoing,
                    body = excluded.body,
                    reply_to_json = excluded.reply_to_json,
                    state = excluded.state,
                    created_at = excluded.created_at,
                    attempt_count = excluded.attempt_count,
                    last_attempt_at = excluded.last_attempt_at,
                    next_attempt_at = excluded.next_attempt_at,
                    ack_deadline = excluded.ack_deadline,
                    last_transport_error = excluded.last_transport_error;",
                params![
                    message.id,
                    message.conversation_id,
                    if message.outgoing { 1 } else { 0 },
                    message.body,
                    encode_reply(message.reply_to)?,
                    message.state.as_str(),
                    message.created_at,
                    relay_payload,
                    ciphertext_hash,
                    i64::from(message.attempt_count),
                    message.last_attempt_at,
                    message.next_attempt_at,
                    message.ack_deadline,
                    message.last_transport_error,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()> {
        self.tx()
            .execute("DELETE FROM messages WHERE id = ?1;", [message_id])
            .map_err(storage_error)?;
        Ok(())
    }

    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                        attempt_count, last_attempt_at, next_attempt_at,
                        ack_deadline, last_transport_error
                 FROM messages
                 WHERE state IN ('QUEUED', 'SENDING')
                   AND next_attempt_at <= CAST(unixepoch('now') * 1000 AS INTEGER)
                 ORDER BY next_attempt_at ASC, created_at ASC, id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>("id")?,
                    row.get::<_, String>("conversation_id")?,
                    row.get::<_, i64>("outgoing")?,
                    row.get::<_, String>("body")?,
                    row.get::<_, Option<String>>("reply_to_json")?,
                    row.get::<_, String>("state")?,
                    row.get::<_, i64>("created_at")?,
                    row.get::<_, i64>("attempt_count")?,
                    row.get::<_, Option<i64>>("last_attempt_at")?,
                    row.get::<_, i64>("next_attempt_at")?,
                    row.get::<_, Option<i64>>("ack_deadline")?,
                    row.get::<_, Option<String>>("last_transport_error")?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (
                id,
                conversation_id,
                outgoing,
                body,
                reply_to_json,
                state,
                created_at,
                attempt_count,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            ) = row.map_err(storage_error)?;
            Ok(ChatMessage {
                id,
                conversation_id,
                outgoing: outgoing != 0,
                body,
                reply_to: decode_reply(reply_to_json)?,
                state: Self::decode_message_state(state)?,
                created_at,
                attempt_count: attempt_count as u32,
                last_attempt_at,
                next_attempt_at,
                ack_deadline,
                last_transport_error,
            })
        })
        .collect()
    }

    fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        let mut statement = self
            .tx()
            .prepare(
                "SELECT envelope_id, message_id, conversation_id, original_sender, received_at
                 FROM delivery_receipts
                 WHERE state IN ('PENDING', 'SENT')
                   AND next_attempt_at <= CAST(unixepoch('now') * 1000 AS INTEGER)
                 ORDER BY next_attempt_at ASC, created_at ASC, envelope_id ASC;",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(ReceiptSendEffect {
                    envelope_id: row.get("envelope_id")?,
                    message_id: row.get("message_id")?,
                    conversation_id: row.get("conversation_id")?,
                    recipient_installation_id: row.get("original_sender")?,
                    received_at: row.get("received_at")?,
                })
            })
            .map_err(storage_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(storage_error)
    }

    fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {
        self.tx()
            .execute(
                "UPDATE messages
                 SET next_attempt_at = 0
                 WHERE state IN ('QUEUED', 'SENDING');",
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                "UPDATE delivery_receipts
                 SET next_attempt_at = 0
                 WHERE state IN ('PENDING', 'SENT');",
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                "UPDATE pairing_outbox
                 SET next_attempt_at = 0
                 WHERE state IN ('PENDING', 'ACCEPTED');",
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                "UPDATE pending_welcomes
                 SET next_attempt_at = 0;",
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn message(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        let message = self
            .tx()
            .query_row(
                "SELECT id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                        attempt_count, last_attempt_at, next_attempt_at,
                        ack_deadline, last_transport_error
                 FROM messages
                 WHERE id = ?1;",
                [message_id],
                |row| {
                    Ok((
                        row.get::<_, String>("id")?,
                        row.get::<_, String>("conversation_id")?,
                        row.get::<_, i64>("outgoing")?,
                        row.get::<_, String>("body")?,
                        row.get::<_, Option<String>>("reply_to_json")?,
                        row.get::<_, String>("state")?,
                        row.get::<_, i64>("created_at")?,
                        row.get::<_, i64>("attempt_count")?,
                        row.get::<_, Option<i64>>("last_attempt_at")?,
                        row.get::<_, i64>("next_attempt_at")?,
                        row.get::<_, Option<i64>>("ack_deadline")?,
                        row.get::<_, Option<String>>("last_transport_error")?,
                    ))
                },
            )
            .optional()
            .map_err(storage_error)?;
        let Some((
            id,
            conversation_id,
            outgoing,
            body,
            reply_to_json,
            state,
            created_at,
            attempt_count,
            last_attempt_at,
            next_attempt_at,
            ack_deadline,
            last_transport_error,
        )) = message
        else {
            return Ok(None);
        };
        Ok(Some(ChatMessage {
            id,
            conversation_id,
            outgoing: outgoing != 0,
            body,
            reply_to: decode_reply(reply_to_json)?,
            state: Self::decode_message_state(state)?,
            created_at,
            attempt_count: attempt_count as u32,
            last_attempt_at,
            next_attempt_at,
            ack_deadline,
            last_transport_error,
        }))
    }
}

const SETTING_IDENTITY: &str = "runtime_identity_v1";
const SETTING_PROFILE: &str = "runtime_profile_v1";
const SETTING_PAIRING_CODE: &str = "pairing_code_v1";

fn encode_reply(
    reply: Option<torchat_client_runtime::MessageReply>,
) -> RuntimeResult<Option<String>> {
    reply
        .map(|value| {
            serde_json::to_string(&value).map_err(|error| RuntimeError::Storage(error.to_string()))
        })
        .transpose()
}

fn decode_reply(
    value: Option<String>,
) -> RuntimeResult<Option<torchat_client_runtime::MessageReply>> {
    value
        .map(|value| {
            serde_json::from_str(&value).map_err(|error| RuntimeError::Storage(error.to_string()))
        })
        .transpose()
}

fn finalize_pairing_item(mut item: PairingItem) -> PairingItem {
    item.available_actions =
        torchat_client_runtime::pairing_available_actions(item.state, item.received);
    item
}

fn invite_state_str(state: InviteState) -> &'static str {
    match state {
        InviteState::Pending => "PENDING",
        InviteState::Accepted => "ACCEPTED",
        InviteState::Rejected => "REJECTED",
        InviteState::Completed => "COMPLETED",
        InviteState::Expired => "EXPIRED",
        InviteState::Archived => "ARCHIVED",
        InviteState::Cancelled => "CANCELLED",
    }
}

fn verification_state_str(state: VerificationState) -> &'static str {
    match state {
        VerificationState::Verified => "VERIFIED",
        VerificationState::Unverified => "UNVERIFIED",
    }
}

fn engine_storage_error(error: rusqlite::Error) -> crate::EngineError {
    crate::EngineError::Storage(format!("{error:#}"))
}

fn storage_engine_error(error: crate::EngineError) -> RuntimeError {
    RuntimeError::Storage(error.to_string())
}

fn storage_error(error: rusqlite::Error) -> RuntimeError {
    RuntimeError::Storage(format!("{error:#}"))
}

fn storage_error_json(error: serde_json::Error) -> RuntimeError {
    RuntimeError::Storage(error.to_string())
}
