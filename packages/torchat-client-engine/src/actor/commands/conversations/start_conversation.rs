use super::super::{CommandHandlerResult, *};
use torchat_runtime::{ClientRuntimeFeatureFacade, RuntimeClock};

impl ClientEngineActor {
    pub(in crate::actor) fn command_start_conversation(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        contact_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (created, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_start_conversation(&contact_id, now_ms)
                    .map(|result| result.value)
            },
            |value| json_response(value),
        )?;
        let _ = self.queue_peer_probe(&contact_id);
        Ok((json_response(created)?, runtime_events, None))
    }
}
