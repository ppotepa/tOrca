use super::super::{CommandHandlerResult, *};
use torchat_runtime::{ClientRuntimeFeatureFacade, RuntimeClock};

impl ClientEngineActor {
    pub(in crate::actor) fn command_accept_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_secs = self.clock.now_secs();
        let (_preparation, mut runtime_events): (PairingPreparation, _) =
            self.with_runtime(|runtime| {
                runtime.feature_prepare_accept_pairing(&pairing_id, now_secs)
            })?;
        let (offer, mut read_events) =
            self.with_runtime(|runtime| runtime.feature_pairing_offer_payload(&pairing_id))?;
        runtime_events.append(&mut read_events);
        let mut accept_events = self.accept_invite(&offer)?;
        runtime_events.append(&mut accept_events);
        let (_, mut commit_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_accept_pairing(&pairing_id)
                    .map(|result| result.value)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        runtime_events.append(&mut commit_events);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
