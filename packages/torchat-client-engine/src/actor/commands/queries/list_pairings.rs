use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_list_pairings(&mut self) -> CommandHandlerResult {
        let ((inbox, outbox), runtime_events) =
            self.with_runtime(|runtime| runtime.local_pairing_lists())?;
        Ok((
            json_response(crate::PairingList { inbox, outbox })?,
            runtime_events,
            None,
        ))
    }
}
