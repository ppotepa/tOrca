use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_rotate_contact_endpoint_capability(
        &mut self,
        installation_id: String,
    ) -> CommandHandlerResult {
        self.database
            .revoke_contact_endpoint_capability(&installation_id)?;
        let capability_id = self
            .database
            .ensure_contact_endpoint_capability(&installation_id)?;
        let _ = self.send_capability_offer(&installation_id);
        let (_, _, sequence, status) = self
            .database
            .contact_endpoint_capability(&installation_id)?
            .ok_or_else(|| EngineError::Storage("capability was not persisted".into()))?;
        let events = vec![torchat_runtime::RuntimeEvent::ContactCapabilityChanged {
            contact_id: installation_id.clone(),
            capability_id: capability_id.clone(),
            sequence,
            status,
        }];
        Ok((
            json_response(ContactCapabilityStatusResponse {
                contact_id: installation_id,
                capability_id,
                sequence,
                status,
            })?,
            events,
            None,
        ))
    }
}
