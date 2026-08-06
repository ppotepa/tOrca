use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_accept_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_secs = self.clock.now_ms() / 1_000;
        let (_preparation, mut runtime_events): (PairingPreparation, _) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_prepare_accept_pairing(
                runtime,
                &pairing_id,
                now_secs,
            )
        })?;
        let (offer, mut read_events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_pairing_offer_payload(
                runtime,
                &pairing_id,
            )
        })?;
        runtime_events.append(&mut read_events);
        let mut accept_events = self.accept_invite(&offer)?;
        runtime_events.append(&mut accept_events);
        let (_, mut commit_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_accept_received_pairing(
                    runtime,
                    &pairing_id,
                )
                .map(|_| ())
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        runtime_events.append(&mut commit_events);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
