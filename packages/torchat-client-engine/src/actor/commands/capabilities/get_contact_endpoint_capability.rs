use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_contact_endpoint_capability(
        &mut self,
        installation_id: String,
    ) -> CommandHandlerResult {
        let capability_id = self
            .database
            .ensure_contact_endpoint_capability(&installation_id)?;
        let (_, _, sequence, status) = self
            .database
            .contact_endpoint_capability(&installation_id)?
            .ok_or_else(|| EngineError::Storage("capability was not persisted".into()))?;
        Ok((
            json_response(ContactCapabilityStatusResponse {
                contact_id: installation_id,
                capability_id,
                sequence,
                status,
            })?,
            Vec::new(),
            None,
        ))
    }
}
