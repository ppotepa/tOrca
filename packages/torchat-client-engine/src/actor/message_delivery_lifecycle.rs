use super::*;
use torchat_runtime::{
    MessageTransportOutcome,
    features::{messaging::ClientRuntimeMessagingFacade, pairing::PairingFeature},
};

impl ClientEngineActor {
    pub(super) fn apply_message_delivery_outcome_with_error(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
        error_detail: Option<&str>,
        retry_at: Option<i64>,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            runtime.feature_apply_message_delivery_outcome(
                message_id,
                outcome,
                retry_at,
                error_detail,
                now_ms,
            )?;
            Ok(())
        })?;
        Ok(runtime_events)
    }

    pub(super) fn apply_message_delivery_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let retry_at = if matches!(
            outcome,
            MessageTransportOutcome::PeerUnavailable | MessageTransportOutcome::RetryableFailure
        ) {
            let attempt = self
                .database
                .outbound_delivery(message_id)?
                .map(|record| record.attempt_count)
                .unwrap_or(0);
            Some(self.clock.now_ms() + retry_backoff_ms(attempt))
        } else {
            None
        };
        self.apply_message_delivery_outcome_with_error(message_id, outcome, None, retry_at)
    }

    pub(super) fn flush_pending_message_deliveries(&mut self) -> EngineResult<()> {
        let now_ms = self.clock.now_ms();
        let (effects, runtime_events) = self
            .with_runtime(|runtime| runtime.feature_prepare_pending_message_deliveries(now_ms))?;
        self.pending_engine_events.extend(
            runtime_events
                .into_iter()
                .map(|event| EngineEvent::Runtime { event }),
        );
        for effect in effects {
            let payload = match self.prepare_outbound_message_payload(&effect) {
                Ok(payload) => payload,
                Err(error) => {
                    let events = self.handle_failed_peer_message_delivery(
                        &effect.recipient_installation_id,
                        &effect.message_id,
                        &error.to_string(),
                    )?;
                    self.pending_engine_events.extend(
                        events
                            .into_iter()
                            .map(|event| EngineEvent::Runtime { event }),
                    );
                    continue;
                }
            };
            let message_id = uuid::Uuid::parse_str(&effect.message_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            let events = self.dispatch_outbound_message(
                &effect,
                message_id,
                stable_message_sequence(message_id),
                payload,
            )?;
            self.pending_engine_events.extend(
                events
                    .into_iter()
                    .map(|event| EngineEvent::Runtime { event }),
            );
        }
        Ok(())
    }

    pub(super) fn flush_pending_pairing_deliveries(&mut self) -> EngineResult<()> {
        let now_secs = self.clock.now_secs();
        let (effects, _) = self.with_runtime(|runtime| {
            PairingFeature::new(runtime.storage_mut()).pending_send_effects(now_secs)
        })?;
        for effect in effects {
            self.deliver_send_effect(effect)?;
        }
        Ok(())
    }
}
