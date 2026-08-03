use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
pub use torchat_client_runtime::RelationshipTransition;
use torchat_client_runtime::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, PeerConnectionStatus,
    PeerEndpointStatus, ReceiptSendEffect, RuntimeError, RuntimeIdentity, RuntimeProfile,
    RuntimeResult, RuntimeStorage, VerificationState,
    logic::{fallback_contact_nickname, normalized_contact_nickname},
};

use super::{
    SqliteTransaction,
    contact_records::verification_state_sql,
    message_queries::{self, MessageQuery},
    message_records::{decode_reply, decode_stored_message, encode_reply, stored_message_row},
    pairing_records::{finalize as finalize_pairing_item, state_sql as invite_state_str},
    settings::{self, IDENTITY_KEY, PAIRING_CODE_KEY, PROFILE_KEY},
    sqlite::{DeliveryReceiptRecord, PendingWelcomeRecord, ReceivedEnvelopeRecord},
    state_codecs,
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

    pub fn apply_relationship_transition(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<()> {
        match transition {
            RelationshipTransition::BeginVerified {
                installation_id,
                boundary_at,
            } => self.begin_verified_relationship(&installation_id, boundary_at),
            RelationshipTransition::Remove {
                installation_id,
                removed_at,
                preserve_history,
                removal_id,
                relationship_epoch,
            } => self.remove_relationship_with_id(
                &installation_id,
                removed_at,
                preserve_history,
                &removal_id,
                relationship_epoch,
            ),
            RelationshipTransition::ApplyRemoteRemoval {
                installation_id,
                remote_removed_at,
                removal_id,
                relationship_epoch,
            } => self.apply_remote_relationship_removal(
                &installation_id,
                remote_removed_at,
                &removal_id,
                relationship_epoch,
            ),
        }
    }

    pub fn rollback(&mut self) -> RuntimeResult<()> {
        self.transaction
            .take()
            .expect("sqlite runtime storage transaction must exist for rollback")
            .rollback()
            .map_err(storage_engine_error)?;
        Ok(())
    }

    fn put_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<()> {
        let secret_hash = Sha256::digest(secret).to_vec();
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_PEER_ENDPOINT_CAPABILITY,
                rusqlite::params![
                    contact_installation_id,
                    capability_id,
                    secret_hash,
                    secret,
                    sequence as i64,
                    issued_at,
                    expires_at
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn revoke_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::REVOKE_PEER_ENDPOINT_CAPABILITY,
                [contact_installation_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    /// Returns the durable projection head for the transaction currently
    /// owned by the runtime.  Keeping this in SQLite (rather than in a
    /// process-local counter) makes the stamp survive engine restarts and
    /// allows the UI to reject stale responses deterministically.
    pub fn projection_head(&self) -> RuntimeResult<(String, u64)> {
        self.tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::PROJECTION_HEAD,
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64)),
            )
            .map_err(storage_error)
    }

    /// Stores an idempotent command result in the transaction currently owned
    /// by the runtime. Callers must invoke this before `commit()` so the
    /// domain mutation and its replay result are durable together.
    pub fn save_processed_command(
        &mut self,
        command_id: &str,
        command_descriptor: &str,
        result_json: &str,
        committed_revision: u64,
    ) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::SAVE_PROCESSED_COMMAND,
                params![
                    command_id,
                    command_descriptor,
                    result_json,
                    committed_revision as i64,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn bump_projection_revision(
        &mut self,
        conversation_ids: &[String],
    ) -> RuntimeResult<(String, u64)> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::BUMP_PROJECTION_REVISION,
                [],
            )
            .map_err(storage_error)?;
        let (store_id, revision) = self.projection_head()?;
        for conversation_id in conversation_ids {
            self.tx()
                .execute(
                    super::sqlite::sql_catalog::runtime_storage::BUMP_CONVERSATION_REVISION,
                    rusqlite::params![conversation_id, revision as i64],
                )
                .map_err(storage_error)?;
        }
        Ok((store_id, revision))
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
        self.put_setting_json(IDENTITY_KEY, &identity)
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
            .transaction()
    }

    fn get_setting_json<T: serde::de::DeserializeOwned>(
        &self,
        key: &'static str,
    ) -> RuntimeResult<Option<T>> {
        let blob: Option<Vec<u8>> = self
            .tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_SETTING_JSON,
                [key],
                |row| row.get("value"),
            )
            .optional()
            .map_err(storage_error)?;
        blob.map(|value| settings::decode(&value)).transpose()
    }

    fn put_setting_json<T: serde::Serialize>(
        &self,
        key: &'static str,
        value: &T,
    ) -> RuntimeResult<()> {
        let payload = settings::encode(value)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_SETTING_JSON,
                params![key, payload],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn remove_pending_local_invite_mls(&mut self, invite_id: &str) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::REMOVE_PENDING_LOCAL_INVITE_MLS,
                [invite_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn put_conversation_mls_snapshot(
        &mut self,
        conversation_id: &str,
        snapshot: &[u8],
    ) -> RuntimeResult<()> {
        let tombstoned: bool = self
            .tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_MLS_SNAPSHOT,
                [conversation_id],
                |row| row.get(0),
            )
            .map_err(storage_error)?;
        if tombstoned {
            return Ok(());
        }
        let snapshot_hash = Sha256::digest(snapshot).to_vec();
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_MLS_SNAPSHOT,
                params![conversation_id, snapshot, snapshot_hash],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    /// Start a verified relationship after an earlier removal.  Tombstones are
    /// deliberately stronger than ordinary contact updates: they suppress MLS
    /// and endpoint writes to prevent delayed frames from resurrecting a
    /// removed relationship.  A newly verified pairing is the sole operation
    /// allowed to clear that barrier, and callers must do so in the same
    /// transaction as the new contact and MLS snapshot.
    pub fn begin_verified_relationship(
        &mut self,
        installation_id: &str,
        boundary_at: i64,
    ) -> RuntimeResult<()> {
        let next_epoch = self
            .tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::BEGIN_VERIFIED_RELATIONSHIP,
                [installation_id],
                |row| row.get::<_, Option<i64>>(0),
            )
            .optional()
            .map_err(storage_error)?
            .flatten()
            .unwrap_or(0)
            .saturating_add(1);
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::BEGIN_VERIFIED_RELATIONSHIP_COMMAND,
                [installation_id],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::BEGIN_VERIFIED_RELATIONSHIP_FINALIZE,
                rusqlite::params![installation_id, boundary_at, next_epoch],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn current_relationship_epoch(&mut self, installation_id: &str) -> RuntimeResult<i64> {
        self.tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::CURRENT_RELATIONSHIP_EPOCH,
                [installation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.unwrap_or(0))
            .map_err(storage_error)
    }

    pub fn put_pending_welcome(&mut self, record: &PendingWelcomeRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_PENDING_WELCOME,
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
                super::sqlite::sql_catalog::runtime_storage::REMOVE_PENDING_WELCOME,
                [invite_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn consume_invite(&mut self, invite_id: &str) -> RuntimeResult<bool> {
        let inserted = self
            .tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::CONSUME_INVITE,
                [invite_id],
            )
            .map_err(storage_error)?;
        Ok(inserted > 0)
    }

    pub fn put_received_envelope(&mut self, value: &ReceivedEnvelopeRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_RECEIVED_ENVELOPE,
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
                super::sqlite::sql_catalog::runtime_storage::PUT_DELIVERY_RECEIPT,
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
                super::sqlite::sql_catalog::runtime_storage::PERSIST_OUTBOUND_ENCRYPTION,
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
                super::sqlite::sql_catalog::runtime_storage::CLAIM_OUTGOING_ATTEMPT,
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
}

impl RuntimeStorage for SqliteRuntimeStorage<'_> {
    fn apply_relationship_transition(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<()> {
        SqliteRuntimeStorage::apply_relationship_transition(self, transition)
    }

    fn begin_verified_relationship(
        &mut self,
        installation_id: &str,
        boundary_at: i64,
    ) -> RuntimeResult<()> {
        SqliteRuntimeStorage::begin_verified_relationship(self, installation_id, boundary_at)
    }

    fn current_relationship_epoch(&mut self, installation_id: &str) -> RuntimeResult<i64> {
        SqliteRuntimeStorage::current_relationship_epoch(self, installation_id)
    }

    fn put_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<()> {
        SqliteRuntimeStorage::put_peer_endpoint_capability(
            self,
            contact_installation_id,
            capability_id,
            secret,
            sequence,
            issued_at,
            expires_at,
        )
    }

    fn revoke_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<()> {
        SqliteRuntimeStorage::revoke_peer_endpoint_capability(self, contact_installation_id)
    }

    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        self.get_setting_json(IDENTITY_KEY)
    }

    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        self.get_setting_json(PROFILE_KEY)
    }

    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        self.put_setting_json(PROFILE_KEY, &profile)
    }

    fn remove_relationship(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> RuntimeResult<()> {
        let removal_id = uuid::Uuid::new_v4().to_string();
        self.remove_relationship_with_id(
            installation_id,
            removed_at,
            preserve_history,
            &removal_id,
            removed_at,
        )
    }

    fn remove_relationship_with_id(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        if installation_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "contact installation id must not be empty".to_owned(),
            ));
        }
        let tx = self.tx();
        let current_epoch = tx
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_RELATIONSHIP_TOMBSTONE_EPOCH,
                [installation_id],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(storage_error)?;
        if current_epoch.is_some_and(|current| relationship_epoch < current) {
            return Ok(());
        }
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::UPSERT_RELATIONSHIP_TOMBSTONE,
            rusqlite::params![
                installation_id,
                removed_at,
                if preserve_history { 1_i64 } else { 0_i64 },
                relationship_epoch,
                removal_id
            ],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::ENQUEUE_RELATIONSHIP_REMOVAL,
            rusqlite::params![
                removal_id,
                installation_id,
                relationship_epoch,
                if preserve_history { 1_i64 } else { 0_i64 }
            ],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::BLOCK_CONTACT,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::SET_CONVERSATION_OFFLINE,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::FAIL_PENDING_MESSAGES,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::DELETE_OUTBOUND_DELIVERIES,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::DELETE_DELIVERY_RECEIPTS,
            [installation_id],
        )
        .map_err(storage_error)?;
        if !preserve_history {
            tx.execute(
                super::sqlite::sql_catalog::runtime_storage::DELETE_HISTORY,
                [installation_id],
            )
            .map_err(storage_error)?;
        }
        for sql in [
            super::sqlite::sql_catalog::runtime_storage::DELETE_MLS,
            super::sqlite::sql_catalog::runtime_storage::DELETE_CONTACT_ENDPOINT,
            super::sqlite::sql_catalog::runtime_storage::DELETE_ENDPOINT_UPDATES,
            super::sqlite::sql_catalog::runtime_storage::DELETE_PEER_BOOTSTRAP,
            super::sqlite::sql_catalog::runtime_storage::DELETE_PENDING_CONFIRMATIONS,
            super::sqlite::sql_catalog::runtime_storage::DELETE_PENDING_ENDPOINT_INBOX,
            super::sqlite::sql_catalog::runtime_storage::DELETE_INBOUND_PEER_ENVELOPES,
            super::sqlite::sql_catalog::runtime_storage::DELETE_RECEIVED_ENVELOPES,
        ] {
            tx.execute(sql, [installation_id]).map_err(storage_error)?;
        }
        Ok(())
    }

    fn apply_remote_relationship_removal(
        &mut self,
        installation_id: &str,
        remote_removed_at: i64,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        if installation_id.trim().is_empty() || removal_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "remote relationship removal identifiers must not be empty".to_owned(),
            ));
        }
        let tx = self.tx();
        let current_epoch = tx
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_REMOTE_TOMBSTONE_EPOCH,
                [installation_id],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(storage_error)?;
        if current_epoch.is_some_and(|current| relationship_epoch < current) {
            return Ok(());
        }
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::UPSERT_REMOTE_TOMBSTONE,
            rusqlite::params![
                installation_id,
                remote_removed_at,
                relationship_epoch,
                removal_id
            ],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::BLOCK_REMOTE_CONTACT,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::SET_REMOTE_CONVERSATION_OFFLINE,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::FAIL_REMOTE_PENDING_MESSAGES,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::DELETE_REMOTE_MLS,
            [installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            super::sqlite::sql_catalog::runtime_storage::ENQUEUE_RELATIONSHIP_REMOVAL_ACK,
            [installation_id],
        )
        .map_err(storage_error)?;
        Ok(())
    }

    fn put_relationship_removal_ack(
        &mut self,
        removal_id: &str,
        contact_installation_id: &str,
        relationship_epoch: i64,
        payload: &[u8],
    ) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::PUT_RELATIONSHIP_REMOVAL_ACK,
                rusqlite::params![
                    removal_id,
                    contact_installation_id,
                    relationship_epoch,
                    payload
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>> {
        self.get_setting_json(PAIRING_CODE_KEY)
    }

    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()> {
        self.put_setting_json(PAIRING_CODE_KEY, &code)
    }

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        let mut statement = self
            .tx()
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_PAIRING_INBOX)
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
                    nickname: normalized_contact_nickname(
                        &sender_installation_id,
                        &sender_nickname,
                    ),
                    installation_id: sender_installation_id,
                    public_key: sender_public_key,
                    fingerprint: sender_fingerprint,
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    verification: VerificationState::Unverified,
                    peer_endpoint_status: PeerEndpointStatus::Missing,
                    peer_connection_status: PeerConnectionStatus::Offline,
                    last_peer_connected_at: None,
                    last_seen_at: None,
                    transport_policy: Default::default(),
                    dev: None,
                }),
                capability: Some(capability),
                expires_at,
                state: state_codecs::invite(state)?,
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
                super::sqlite::sql_catalog::runtime_storage::UPSERT_PAIRING_INBOX,
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
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_PAIRING_OUTBOX)
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
                    nickname: fallback_contact_nickname(&installation_id),
                    public_key: String::new(),
                    fingerprint: String::new(),
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    installation_id,
                    verification: VerificationState::Unverified,
                    peer_endpoint_status: PeerEndpointStatus::Missing,
                    peer_connection_status: PeerConnectionStatus::Offline,
                    last_peer_connected_at: None,
                    last_seen_at: None,
                    transport_policy: Default::default(),
                    dev: None,
                }),
                capability,
                expires_at,
                state: state_codecs::invite(state)?,
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
                super::sqlite::sql_catalog::runtime_storage::UPSERT_PAIRING_OUTBOX,
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
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_CONTACTS)
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
                    row.get::<_, String>("transport_policy")?,
                    row.get::<_, i64>("has_peer_endpoint")?,
                    row.get::<_, i64>("has_pending_peer_exchange")?,
                    row.get::<_, i64>("has_recent_peer_connection")?,
                    row.get::<_, Option<i64>>("last_connected_at")?,
                    row.get::<_, Option<i64>>("last_seen_at")?,
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
                transport_policy,
                has_peer_endpoint,
                has_pending_peer_exchange,
                has_recent_peer_connection,
                last_peer_connected_at,
                last_seen_at,
            ) = row.map_err(storage_error)?;
            Ok(ContactRecord {
                installation_id,
                nickname,
                public_key,
                fingerprint,
                local_alias,
                muted: muted != 0,
                blocked: blocked != 0,
                verification: state_codecs::verification(verification)?,
                peer_endpoint_status: if has_peer_endpoint != 0 {
                    PeerEndpointStatus::Verified
                } else if has_pending_peer_exchange != 0 {
                    PeerEndpointStatus::PendingExchange
                } else {
                    PeerEndpointStatus::Missing
                },
                // A queued delivery retry is not proof of a live peer
                // connection. Reachability is owned by the engine event path.
                peer_connection_status: if has_recent_peer_connection != 0 {
                    PeerConnectionStatus::Connected
                } else {
                    PeerConnectionStatus::Offline
                },
                transport_policy: serde_json::from_str(&format!("\"{transport_policy}\""))
                    .unwrap_or_default(),
                last_peer_connected_at,
                last_seen_at,
                dev: None,
            })
        })
        .collect()
    }

    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()> {
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::UPSERT_CONTACT,
                params![
                    contact.installation_id,
                    contact.nickname,
                    contact.public_key,
                    contact.fingerprint,
                    verification_state_sql(contact.verification),
                    contact.local_alias,
                    if contact.muted { 1 } else { 0 },
                    if contact.blocked { 1 } else { 0 },
                    serde_json::to_string(&contact.transport_policy)
                        .unwrap_or_else(|_| "\"PEER_ONLY\"".to_owned())
                        .trim_matches('"'),
                    contact.last_seen_at,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        let mut statement = self
            .tx()
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_CONVERSATIONS)
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
                status: state_codecs::conversation(state)?,
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
                super::sqlite::sql_catalog::runtime_storage::UPSERT_CONVERSATION,
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
                super::sqlite::sql_catalog::runtime_storage::MARK_CONVERSATION_READ,
                [conversation_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        match message_queries::parse(conversation_id)? {
            MessageQuery::All { conversation_id } => {
                let mut statement = self
                    .tx()
                    .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_MESSAGES)
                    .map_err(storage_error)?;
                let rows = statement
                    .query_map([conversation_id], stored_message_row)
                    .map_err(storage_error)?;
                rows.map(|row| decode_stored_message(row.map_err(storage_error)?))
                    .collect()
            }
            MessageQuery::Page {
                conversation_id,
                limit,
                before,
            } => {
                let mut messages = if let Some((before_created_at, before_id)) = before {
                    let mut statement = self
                        .tx()
                        .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_MESSAGES_BEFORE)
                        .map_err(storage_error)?;
                    let rows = statement
                        .query_map(
                            params![conversation_id, before_created_at, before_id, limit as i64],
                            stored_message_row,
                        )
                        .map_err(storage_error)?;
                    rows.map(|row| decode_stored_message(row.map_err(storage_error)?))
                        .collect::<RuntimeResult<Vec<_>>>()?
                } else {
                    let mut statement = self
                        .tx()
                        .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_MESSAGES_LIMITED)
                        .map_err(storage_error)?;
                    let rows = statement
                        .query_map(params![conversation_id, limit as i64], stored_message_row)
                        .map_err(storage_error)?;
                    rows.map(|row| decode_stored_message(row.map_err(storage_error)?))
                        .collect::<RuntimeResult<Vec<_>>>()?
                };
                messages.reverse();
                Ok(messages)
            }
        }
    }

    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()> {
        let existing = self
            .tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_MESSAGE_METADATA,
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
                super::sqlite::sql_catalog::runtime_storage::UPSERT_MESSAGE,
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
            .execute(
                super::sqlite::sql_catalog::runtime_storage::DELETE_MESSAGE,
                [message_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
        let mut statement = self
            .tx()
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_PENDING_MESSAGES)
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
                state: state_codecs::message(state)?,
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
            .prepare(super::sqlite::sql_catalog::runtime_storage::LIST_PENDING_RECEIPTS)
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
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_MESSAGE_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_RECEIPT_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_READ_RECEIPT_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_PAIRING_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_CONFIRMATION_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_ENDPOINT_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        self.tx()
            .execute(
                super::sqlite::sql_catalog::runtime_storage::EXPEDITE_CAPABILITY_RETRIES,
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn message(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        let message = self
            .tx()
            .query_row(
                super::sqlite::sql_catalog::runtime_storage::GET_MESSAGE,
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
            state: state_codecs::message(state)?,
            created_at,
            attempt_count: attempt_count as u32,
            last_attempt_at,
            next_attempt_at,
            ack_deadline,
            last_transport_error,
        }))
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
