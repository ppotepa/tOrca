use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_reject_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let (effect, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.commit_reject_pairing(&pairing_id),
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(effect)?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
