use super::*;

impl ClientEngineActor {
    pub(crate) fn handle_relay_event(
        &mut self,
        event: RelayEvent,
    ) -> EngineResult<(
        Vec<torchat_runtime::RuntimeEvent>,
        Option<ConnectionSnapshot>,
        Option<EngineLogEvent>,
    )> {
        match event {
            RelayEvent::PairingAvailable { pairing_id } => {
                let events = self.apply_pairing_peer_outcome(
                    &pairing_id.to_string(),
                    PairingPeerOutcome::RejectionReceived,
                )?;
                Ok((events, None, None))
            }
            RelayEvent::PairingFinalized { pairing_id } => {
                let (_, events) =
                    self.with_runtime(|runtime| runtime.finalize_pairing(&pairing_id.to_string()))?;
                Ok((events, None, None))
            }
            RelayEvent::Envelope(envelope) => self
                .handle_relay_envelope(envelope)
                .map(|events| (events, None, None)),
        }
    }
}
