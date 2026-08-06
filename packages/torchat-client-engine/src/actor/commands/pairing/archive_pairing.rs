use super::super::{CommandHandlerResult, *};
use torchat_runtime::ClientRuntimeFeatureFacade;

impl ClientEngineActor {
    pub(in crate::actor) fn command_archive_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_archive_pairing(&pairing_id)
                    .map(|result| result.value)
            },
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
