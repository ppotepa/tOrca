use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_peer_endpoint(&mut self) -> CommandHandlerResult {
        Ok((
            json_response(self.local_peer_endpoint.clone())?,
            Vec::new(),
            None,
        ))
    }
}
