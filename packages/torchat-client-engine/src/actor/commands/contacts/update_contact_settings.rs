use super::super::{CommandHandlerResult, *};
use torchat_runtime::ClientRuntimeFeatureFacade;

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
                runtime
                    .feature_update_contact_settings(
                        &installation_id,
                        local_alias,
                        muted,
                        blocked,
                        transport_policy,
                    )
                    .map(|result| result.value)
            },
            |value| json_response(value),
        )?;
        Ok((json_response(contact)?, runtime_events, None))
    }
}
