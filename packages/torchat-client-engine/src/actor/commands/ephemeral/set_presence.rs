use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_set_presence(&mut self, online: bool) -> CommandHandlerResult {
        let peers = self.conversations.keys().cloned().collect::<Vec<_>>();
        for peer in peers {
            self.queue_peer_presence(&peer, online)?;
        }
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
