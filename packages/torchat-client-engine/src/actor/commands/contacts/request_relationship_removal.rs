use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_request_relationship_removal(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
        preserve_history: bool,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.remove_relationship(&installation_id, preserve_history),
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.conversations.remove(&installation_id);
        self.crypto_blocked_peers.remove(&installation_id);
        self.active_peer_sessions.remove(&installation_id);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
