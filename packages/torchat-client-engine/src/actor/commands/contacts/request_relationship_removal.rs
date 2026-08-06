use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_request_relationship_removal(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
        preserve_history: bool,
    ) -> CommandHandlerResult {
        let removed_at = self.clock.now_ms();
        let removal_id = uuid::Uuid::new_v4().to_string();
        let operation_id = idempotency
            .map(|context| context.command_id.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let command_descriptor = idempotency
            .map(|context| context.command_descriptor.clone())
            .unwrap_or_else(|| {
                format!(
                    "request_relationship_removal:{}:{}",
                    installation_id, preserve_history
                )
            });

        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                let result = torchat_runtime::features::relationship_removal::RelationshipRemovalFeature::new(
                    runtime.storage_mut(),
                )
                .request(
                    &operation_id,
                    &command_descriptor,
                    &installation_id,
                    preserve_history,
                    &removal_id,
                    removed_at,
                )?;
                if !result.changes.sections.is_empty() {
                    for kind in [
                        "operations",
                        "relationships",
                        "contacts",
                        "conversations",
                        "messages",
                    ] {
                        runtime.session_mut().push_event(torchat_runtime::RuntimeEvent::Changed {
                            kind: Some(kind.to_owned()),
                        });
                    }
                }
                Ok(())
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.conversations.remove(&installation_id);
        self.crypto_blocked_peers.remove(&installation_id);
        self.active_peer_sessions.remove(&installation_id);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
