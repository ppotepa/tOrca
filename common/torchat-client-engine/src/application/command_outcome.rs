use torchat_client_runtime::RuntimeEvent;

use crate::{
    event::ResponsePayload, ConnectionSnapshot,
};

use super::EngineEffect;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ProjectionDirty {
    #[default]
    None,
    Profile,
    Contacts,
    Conversations,
    Pairing,
    Connection,
    Multiple,
}

#[derive(Clone, Debug)]
pub struct CommandOutcome {
    pub response: ResponsePayload,
    pub runtime_events: Vec<RuntimeEvent>,
    pub effects: Vec<EngineEffect>,
    pub connection_snapshot: Option<ConnectionSnapshot>,
    pub projection_dirty: ProjectionDirty,
}

impl CommandOutcome {
    pub fn empty(response: ResponsePayload) -> Self {
        Self {
            response,
            runtime_events: Vec::new(),
            effects: Vec::new(),
            connection_snapshot: None,
            projection_dirty: ProjectionDirty::None,
        }
    }

    pub fn from_legacy(
        response: ResponsePayload,
        runtime_events: Vec<RuntimeEvent>,
        connection_snapshot: Option<ConnectionSnapshot>,
    ) -> Self {
        Self {
            response,
            runtime_events,
            effects: Vec::new(),
            connection_snapshot,
            projection_dirty: ProjectionDirty::None,
        }
    }

    pub fn with_effect(mut self, effect: EngineEffect) -> Self {
        self.effects.push(effect);
        self
    }

    pub fn mark_projection(mut self, dirty: ProjectionDirty) -> Self {
        self.projection_dirty = dirty;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_adapter_preserves_response_and_events() {
        let event = RuntimeEvent::RuntimeReady { protocol: 1 };
        let outcome = CommandOutcome::from_legacy(
            ResponsePayload::Empty,
            vec![event.clone()],
            None,
        );

        assert!(matches!(outcome.response, ResponsePayload::Empty));
        assert_eq!(outcome.runtime_events, vec![event]);
        assert!(outcome.effects.is_empty());
        assert_eq!(outcome.projection_dirty, ProjectionDirty::None);
    }
}
