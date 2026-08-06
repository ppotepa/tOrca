use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_request_relationship_removal(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
        preserve_history: bool,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                let removal = torchat_runtime::ClientRelationshipFeatureFacade::feature_request_relationship_removal(
                    runtime,
                    &installation_id,
                    now_ms,
                    preserve_history,
                )?
                .value;
                torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                    runtime,
                    &removal.removal_id,
                    torchat_runtime::OperationType::RelationshipRemoval,
                    &installation_id,
                    now_ms,
                )?;
                Ok(removal)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.conversations.remove(&installation_id);
        self.crypto_blocked_peers.remove(&installation_id);
        self.active_peer_sessions.remove(&installation_id);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
