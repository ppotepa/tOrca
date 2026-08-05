use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_bootstrap(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
    ) -> CommandHandlerResult {
        let (bootstrapped, mut runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.bootstrap_runtime(),
            |value| json_response(value),
        )?;
        runtime_events.push(transport_status_event(
            torchat_runtime::TransportComponent::Engine,
            torchat_runtime::TransportProbeState::Ready,
            "engine and local storage ready",
            None,
            None,
            0,
            None,
            self.connection_generation,
            None,
            self.clock.now_ms(),
        ));
        Ok((json_response(bootstrapped)?, runtime_events, None))
    }
}
