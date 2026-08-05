use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_connect(&mut self) -> CommandHandlerResult {
        if self.connect_requested && self.connection_state == ConnectionState::Connected {
            let (connected, runtime_events) = self.with_runtime(|runtime| runtime.connect())?;
            return Ok((
                json_response(connected)?,
                runtime_events,
                Some(self.connection_snapshot("connect requested; local transport ready")),
            ));
        }
        self.advance_connection_generation();
        self.connect_requested = true;
        self.connection_state = if self.socks5_url.is_some() {
            ConnectionState::Connecting
        } else {
            ConnectionState::WaitingForTor
        };
        let (connected, runtime_events) = self.with_runtime(|runtime| runtime.connect())?;
        self.flush_pending_send_effects()?;
        self.flush_pending_receipt_effects()?;
        Ok((
            json_response(connected)?,
            runtime_events,
            Some(self.connection_snapshot("connect requested")),
        ))
    }
}
