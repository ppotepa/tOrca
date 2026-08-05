use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    #[allow(clippy::too_many_arguments)]
    pub(in crate::actor) fn command_update_contact_settings(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
        transport_policy: Option<torchat_runtime::ContactTransportPolicy>,
    ) -> CommandHandlerResult {
        let (contact, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                let mut contact = runtime.update_contact_settings(
                    &installation_id,
                    local_alias,
                    muted,
                    blocked,
                )?;
                if let Some(policy) = transport_policy {
                    contact = runtime.set_contact_transport_policy(&installation_id, policy)?;
                }
                Ok(contact)
            },
            |value| json_response(value),
        )?;
        Ok((json_response(contact)?, runtime_events, None))
    }
}
