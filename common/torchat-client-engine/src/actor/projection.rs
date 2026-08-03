use torchat_client_runtime::{
    ApplicationSnapshot, PairingSummary, ProjectionStamp, RuntimeClock, RuntimeIdentity,
    RuntimeProfile, RuntimeStorage, UiCheckpoint,
};

use super::{ClientEngineActor, runtime_error};
use crate::{EngineError, EngineResult, storage::SqliteRuntimeStorage};

impl ClientEngineActor {
    pub(super) fn runtime_profile(&mut self) -> EngineResult<RuntimeProfile> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let profile = storage
            .profile()
            .map_err(runtime_error)?
            .ok_or_else(|| EngineError::Storage("runtime profile is missing".to_owned()))?;
        storage.rollback().map_err(runtime_error)?;
        Ok(profile)
    }

    pub(super) fn runtime_identity(&mut self) -> EngineResult<RuntimeIdentity> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let identity = storage
            .identity()
            .map_err(runtime_error)?
            .ok_or_else(|| EngineError::Storage("runtime identity is missing".to_owned()))?;
        storage.rollback().map_err(runtime_error)?;
        Ok(identity)
    }

    /// Read the application projection from one SQLite transaction.  The
    /// projection stamp is read from the same transaction as contacts,
    /// conversations and pairing state, so Flutter never has to assemble a
    /// mixed-revision snapshot with `Future.wait`.
    pub(super) fn application_snapshot(&mut self) -> EngineResult<ApplicationSnapshot> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let identity = storage
            .identity()
            .map_err(runtime_error)?
            .ok_or_else(|| EngineError::Storage("runtime identity is missing".to_owned()))?;
        let profile = storage.profile().map_err(runtime_error)?;
        let contacts = storage.contacts().map_err(runtime_error)?;
        let conversations = storage.conversations().map_err(runtime_error)?;
        let inbox = storage.pairing_inbox().map_err(runtime_error)?;
        let outbox = storage.pairing_outbox().map_err(runtime_error)?;
        let (store_id, revision) = storage.projection_head().map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(ApplicationSnapshot {
            schema_version: torchat_client_runtime::APPLICATION_SNAPSHOT_SCHEMA_VERSION,
            generation: revision,
            created_at_ms: self.clock.now_ms(),
            identity,
            profile,
            contacts,
            conversations,
            pairing_summary: PairingSummary {
                pending_inbox: inbox
                    .iter()
                    .filter(|item| item.state.is_outstanding())
                    .count() as u32,
                pending_outbox: outbox
                    .iter()
                    .filter(|item| item.state.is_outstanding())
                    .count() as u32,
            },
            peer_endpoint_available: self.local_peer_endpoint.is_some(),
            ui_checkpoint: UiCheckpoint::default(),
            projection: ProjectionStamp {
                store_id,
                engine_session_id: self.engine_session_id.clone(),
                revision,
            },
        })
        .map(|snapshot| snapshot.normalize())
    }

    pub(super) fn projection_head(&self) -> EngineResult<(String, u64)> {
        self.database.projection_head()
    }
    pub(super) fn list_contacts(
        &mut self,
    ) -> EngineResult<Vec<torchat_client_runtime::ContactRecord>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let contacts = storage.contacts().map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(contacts)
    }

    pub(super) fn list_conversations(
        &mut self,
    ) -> EngineResult<Vec<torchat_client_runtime::ConversationSummary>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let conversations = storage.conversations().map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(conversations)
    }

    pub(super) fn list_messages(
        &mut self,
        conversation_id: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::ChatMessage>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let messages = storage.messages(conversation_id).map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(messages)
    }
}
