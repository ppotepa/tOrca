use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_reject_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_secs = self.clock.now_ms() / 1_000;
        let (effect, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_commit_reject_pairing(
                    runtime,
                    &pairing_id,
                    now_secs,
                )
                .map(|result| result.value)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(effect)?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
