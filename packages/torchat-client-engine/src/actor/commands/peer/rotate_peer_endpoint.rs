use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_rotate_peer_endpoint(&mut self) -> CommandHandlerResult {
        self.expected_onion_generation = self.expected_onion_generation.saturating_add(1);
        self.pending_engine_events
            .push(EngineEvent::PlatformAction {
                action: PlatformAction::RotateOnionService {
                    generation: self.expected_onion_generation,
                },
            });
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
