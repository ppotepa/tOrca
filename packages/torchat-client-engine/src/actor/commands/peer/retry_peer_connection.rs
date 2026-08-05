use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_retry_peer_connection(
        &mut self,
        installation_id: String,
    ) -> CommandHandlerResult {
        if self
            .database
            .contact_peer_endpoint(&installation_id)?
            .is_some()
        {
            let _ = self.queue_peer_probe(&installation_id);
            self.database.expedite_peer_deliveries(&installation_id)?;
            self.flush_pending_send_effects()?;
        }
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
