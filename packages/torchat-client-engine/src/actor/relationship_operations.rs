use super::*;

impl ClientEngineActor {
    pub(super) fn complete_relationship_removal_operation(
        &mut self,
        removal_id: &str,
        installation_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientOperationFeatureFacade::feature_ensure_operation(
                runtime,
                removal_id,
                torchat_runtime::OperationType::RelationshipRemoval,
                installation_id,
                now_ms,
            )?;
            torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                runtime,
                removal_id,
                now_ms,
            )?;
            Ok(())
        })?;
        Ok(runtime_events)
    }
}
