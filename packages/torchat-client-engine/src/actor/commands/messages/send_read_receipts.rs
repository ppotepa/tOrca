use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_send_read_receipts(
        &mut self,
        conversation_id: String,
    ) -> CommandHandlerResult {
        let message_ids = self
            .list_messages(&conversation_id)?
            .into_iter()
            .filter(|message| !message.outgoing)
            .filter_map(|message| uuid::Uuid::parse_str(&message.id).ok())
            .collect::<Vec<_>>();
        if !message_ids.is_empty() {
            self.queue_read_receipts(&conversation_id, message_ids)?;
        }
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
