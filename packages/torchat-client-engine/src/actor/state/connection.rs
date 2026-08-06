use super::*;

impl ClientEngineActor {
    pub(crate) fn connection_snapshot(&self, detail: &str) -> ConnectionSnapshot {
        ConnectionSnapshot {
            state: self.connection_state.clone(),
            generation: self.connection_generation,
            detail: detail.to_owned(),
        }
    }

    pub(crate) fn advance_connection_generation(&mut self) {
        self.connection_generation = self.connection_generation.saturating_add(1);
    }
}
