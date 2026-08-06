use super::super::{CommandHandlerResult, *};
use torchat_runtime::features::conversations::ClientRuntimeConversationFacade;

impl ClientEngineActor {
    pub(in crate::actor) fn command_set_conversation_focus(
        &mut self,
        conversation_id: String,
        focused: bool,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime(|runtime| {
            runtime.feature_set_conversation_focus(&conversation_id, focused)
        })?;
        self.queue_peer_conversation_focus(&conversation_id, focused)?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
