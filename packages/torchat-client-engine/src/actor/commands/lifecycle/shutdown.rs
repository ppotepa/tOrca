use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_shutdown(&mut self) -> CommandHandlerResult {
        self.advance_connection_generation();
        self.relay.shutdown();
        self.connection_state = ConnectionState::Stopped;
        Ok((
            ResponsePayload::Empty,
            Vec::new(),
            Some(self.connection_snapshot("shutdown requested")),
        ))
    }
}
