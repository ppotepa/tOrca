use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_archive_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_archive_pairing(
                    runtime,
                    &pairing_id,
                )
                .map(|_| ())
            },
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
