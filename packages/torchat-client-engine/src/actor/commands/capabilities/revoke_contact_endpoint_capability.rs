use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_revoke_contact_endpoint_capability(
        &mut self,
        installation_id: String,
    ) -> CommandHandlerResult {
        if let Some((capability_id, _, sequence, _)) = self
            .database
            .contact_endpoint_capability(&installation_id)?
        {
            let _ = self.send_ephemeral_payload(
                &installation_id,
                ApplicationPayloadV1::CapabilityRevoked {
                    version: torchat_core::PROTOCOL_VERSION,
                    capability_id,
                    sequence,
                    revoked_at: self.clock.now_ms() / 1_000,
                },
            );
        }
        self.database
            .revoke_contact_endpoint_capability(&installation_id)?;
        self.database
            .complete_capability_deliveries_for_contact(&installation_id)?;
        self.active_peer_sessions.remove(&installation_id);
        Ok((
            ResponsePayload::Empty,
            vec![torchat_runtime::RuntimeEvent::ContactCapabilityChanged {
                contact_id: installation_id,
                capability_id: String::new(),
                sequence: 0,
                status: torchat_runtime::CapabilityStatus::Revoked,
            }],
            None,
        ))
    }
}
