use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_code_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        code: torchat_runtime::InviteCode,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                let result = torchat_runtime::features::pairing_preparation::PairingPreparationFeature::new(
                    runtime.storage_mut(),
                )
                .commit_code(code.clone())?;
                if !result.changes.sections.is_empty() {
                    runtime.session_mut().push_event(torchat_runtime::RuntimeEvent::Changed {
                        kind: Some("pairings".to_owned()),
                    });
                }
                Ok(result.value)
            },
            |value| json_response(value),
        )
        .and_then(|(value, events)| Ok((json_response(value)?, events)))
    }
}
