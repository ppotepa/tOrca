use std::mem;

use torchat_client_runtime::ClientRuntime;
use torchat_core::mls::DirectConversation;

use super::{
    ClientEngineActor, EngineRuntimeTransport, IdempotencyCommitContext, SharedRuntimeClock,
    runtime_error,
};
use crate::fault_injection::FaultPoint;
use crate::{EngineError, EngineResult, event::ResponsePayload, storage::SqliteRuntimeStorage};

impl ClientEngineActor {
    pub(super) fn with_runtime<R>(
        &mut self,
        op: impl FnOnce(
            &mut ClientRuntime<
                SqliteRuntimeStorage<'_>,
                EngineRuntimeTransport<'_>,
                SharedRuntimeClock,
            >,
        ) -> torchat_client_runtime::RuntimeResult<R>,
    ) -> EngineResult<(R, Vec<torchat_client_runtime::RuntimeEvent>)> {
        self.with_runtime_internal(op, None, |_| Ok(None))
    }

    pub(super) fn with_runtime_idempotent<R>(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        op: impl FnOnce(
            &mut ClientRuntime<
                SqliteRuntimeStorage<'_>,
                EngineRuntimeTransport<'_>,
                SharedRuntimeClock,
            >,
        ) -> torchat_client_runtime::RuntimeResult<R>,
        response: impl FnOnce(&R) -> EngineResult<ResponsePayload>,
    ) -> EngineResult<(R, Vec<torchat_client_runtime::RuntimeEvent>)> {
        self.with_runtime_internal(op, idempotency, |value| response(value).map(Some))
    }

    fn with_runtime_internal<R>(
        &mut self,
        op: impl FnOnce(
            &mut ClientRuntime<
                SqliteRuntimeStorage<'_>,
                EngineRuntimeTransport<'_>,
                SharedRuntimeClock,
            >,
        ) -> torchat_client_runtime::RuntimeResult<R>,
        idempotency: Option<&IdempotencyCommitContext>,
        response: impl FnOnce(&R) -> EngineResult<Option<ResponsePayload>>,
    ) -> EngineResult<(R, Vec<torchat_client_runtime::RuntimeEvent>)> {
        let storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let transport = EngineRuntimeTransport {
            status: self.tor_status.clone(),
            _actor: std::marker::PhantomData,
        };
        let session = mem::take(&mut self.session);
        let mut runtime =
            ClientRuntime::with_session(storage, transport, self.clock.clone(), session);
        let session_before = runtime.session().clone();
        runtime.session_mut().begin_transaction();

        let result = match op(&mut runtime) {
            Ok(value) => {
                // A read or a transient transport update must not manufacture
                // a new durable projection revision.  The runtime stages its
                // domain events in this transaction, which lets us advance
                // the head only for state the UI can actually project.
                let (projection_changed, conversation_ids) =
                    runtime.session().pending_projection_changes();
                let mut committed_revision = runtime
                    .storage()
                    .projection_head()
                    .map_err(runtime_error)?
                    .1;
                if projection_changed {
                    let (_, revision) = runtime
                        .storage_mut()
                        .bump_projection_revision(&conversation_ids)
                        .map_err(runtime_error)?;
                    committed_revision = revision;
                }
                if let Some(context) = idempotency {
                    let payload = response(&value)?;
                    if let Some(payload) = payload {
                        let result_json = serde_json::to_string(&payload)?;
                        runtime
                            .storage_mut()
                            .save_processed_command(
                                &context.command_id,
                                &context.command_descriptor,
                                &result_json,
                                committed_revision,
                            )
                            .map_err(runtime_error)?;
                    }
                }
                self.fault_injector.hit(FaultPoint::BeforeLocalCommit)?;
                match runtime.storage_mut().commit() {
                    Ok(()) => {
                        runtime.session_mut().commit_transaction();
                        self.fault_injector
                            .hit(FaultPoint::AfterLocalCommitBeforeDispatch)?;
                        Ok((value, projection_changed, conversation_ids))
                    }
                    Err(error) => {
                        runtime.session_mut().rollback_transaction();
                        runtime.restore_session(session_before);
                        Err(error)
                    }
                }
            }
            Err(error) => {
                let _ = runtime.storage_mut().rollback();
                runtime.session_mut().rollback_transaction();
                runtime.restore_session(session_before);
                Err(error)
            }
        };

        let events = if result.is_ok() {
            runtime.drain_events()
        } else {
            Vec::new()
        };
        let (_, transport, _, session) = runtime.into_parts_with_session();
        self.session = session;
        self.tor_status = transport.status;
        let (value, projection_changed, conversation_ids) = result.map_err(runtime_error)?;
        if let Some(anchor) = self.mls_anchor.as_deref_mut() {
            for conversation_id in &conversation_ids {
                if let Some(record) = self.database.conversation_mls_checkpoint(conversation_id)? {
                    let epoch = DirectConversation::restore(&record.snapshot)
                        .map_err(EngineError::Storage)?
                        .epoch();
                    anchor.record_checkpoint(
                        conversation_id,
                        &crate::anti_rollback::AnchoredMlsCheckpoint {
                            state_version: record.state_version,
                            epoch,
                            snapshot_hash: record.snapshot_hash.unwrap_or_default(),
                        },
                    )?;
                }
            }
        }
        if projection_changed && let Ok((store_id, revision)) = self.database.projection_head() {
            let mut events = events;
            events.push(torchat_client_runtime::RuntimeEvent::ProjectionChanged {
                store_id,
                engine_session_id: self.engine_session_id.clone(),
                revision,
                application: true,
                conversation_ids,
            });
            return Ok((value, events));
        }
        Ok((value, events))
    }
}
