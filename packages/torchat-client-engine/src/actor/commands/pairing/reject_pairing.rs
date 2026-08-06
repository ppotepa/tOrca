use super::super::{CommandHandlerResult, *};
use torchat_runtime::{ClientRuntimeFeatureFacade, RuntimeClock};

impl ClientEngineActor {
    pub(in crate::actor) fn command_reject_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_secs = self.clock.now_secs();
        let (effect, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_reject_pairing(&pairing_id, now_secs)
                    .map(|result| result.value.0)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(effect)?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
