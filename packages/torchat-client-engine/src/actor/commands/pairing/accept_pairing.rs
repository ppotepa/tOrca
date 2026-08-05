use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_accept_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let (_preparation, mut runtime_events): (PairingPreparation, _) =
            self.with_runtime(|runtime| runtime.prepare_accept_pairing(&pairing_id))?;
        let (offer, mut read_events) =
            self.with_runtime(|runtime| runtime.pairing_offer_payload(&pairing_id))?;
        runtime_events.append(&mut read_events);
        let mut accept_events = self.accept_invite(&offer)?;
        runtime_events.append(&mut accept_events);
        let (_, mut commit_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.accept_received_pairing(&pairing_id),
            |_| Ok(ResponsePayload::Empty),
        )?;
        runtime_events.append(&mut commit_events);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
