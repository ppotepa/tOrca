use super::*;

impl ClientEngineActor {
    pub(super) fn flush_pending_feature_send_effects(&mut self) -> EngineResult<()> {
        let (message_effects, _) = self.with_runtime(|runtime| {
            torchat_runtime::ClientRuntimeFeatureFacade::feature_pending_message_sends(runtime)
        })?;
        for effect in message_effects {
            self.deliver_send_effect(RuntimeSendEffect::from(effect))?;
        }

        let now_secs = self.clock.now_ms() / 1_000;
        let (pairing_effects, _) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_pending_pairing_send_effects(
                runtime,
                now_secs,
            )
        })?;
        for effect in pairing_effects {
            self.deliver_send_effect(effect)?;
        }

        self.flush_pending_relationship_removal_acks()?;
        self.flush_pending_relationship_removals()?;
        Ok(())
    }
}
