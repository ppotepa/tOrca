use crate::{EngineEvent, effects::EngineEffectEnvelope, input::EngineInputEnvelope};
use torchat_runtime::{ChangeSet, RuntimeEvent};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ProcessingControl {
    Continue,
    Stop,
}

pub(crate) struct EngineProcessingResult {
    pub events: Vec<EngineEvent>,
    pub effects: Vec<EngineEffectEnvelope>,
    pub derived_inputs: Vec<EngineInputEnvelope>,
    pub changes: ChangeSet,
    pub scheduler_plan_changed: bool,
    pub control: ProcessingControl,
}

impl EngineProcessingResult {
    pub(crate) fn empty() -> Self {
        Self {
            events: Vec::new(),
            effects: Vec::new(),
            derived_inputs: Vec::new(),
            changes: ChangeSet::none(),
            scheduler_plan_changed: false,
            control: ProcessingControl::Continue,
        }
    }

    pub(crate) fn stop(events: Vec<EngineEvent>) -> Self {
        let mut result = Self::empty();
        result.control = ProcessingControl::Stop;
        result.extend_engine_events(events);
        result
    }

    pub(crate) fn extend_runtime_events(&mut self, events: impl IntoIterator<Item = RuntimeEvent>) {
        for event in events {
            self.changes.merge(ChangeSet::from_runtime_event(&event));
            self.events.push(EngineEvent::Runtime { event });
        }
    }

    pub(crate) fn extend_engine_events(&mut self, events: impl IntoIterator<Item = EngineEvent>) {
        for event in events {
            if let EngineEvent::Runtime {
                event: runtime_event,
            } = &event
            {
                self.changes
                    .merge(ChangeSet::from_runtime_event(runtime_event));
            }
            self.events.push(event);
        }
    }

    pub(crate) fn append_engine_events(&mut self, events: &mut Vec<EngineEvent>) {
        self.extend_engine_events(events.drain(..));
    }

    pub(crate) fn should_stop(&self) -> bool {
        self.control == ProcessingControl::Stop
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use torchat_runtime::ChangeSections;

    #[test]
    fn empty_result_continues_without_outputs() {
        let result = EngineProcessingResult::empty();

        assert!(result.events.is_empty());
        assert!(result.effects.is_empty());
        assert!(result.derived_inputs.is_empty());
        assert!(result.changes.sections.is_empty());
        assert!(!result.scheduler_plan_changed);
        assert!(!result.should_stop());
    }

    #[test]
    fn runtime_events_contribute_to_one_change_set() {
        let mut result = EngineProcessingResult::empty();
        result.extend_runtime_events([
            RuntimeEvent::InviteStateChanged {
                pairing_id: Some("pairing-1".to_owned()),
                state: None,
            },
            RuntimeEvent::MessageStateChanged {
                message_id: None,
                conversation_id: Some("conversation-1".to_owned()),
                state: None,
            },
        ]);

        assert!(result.changes.sections.contains(ChangeSections::PAIRINGS));
        assert!(result.changes.sections.contains(ChangeSections::MESSAGES));
        assert!(
            result
                .changes
                .entities
                .conversation_ids
                .contains("conversation-1")
        );
    }

    #[test]
    fn stop_result_has_explicit_control() {
        let result = EngineProcessingResult::stop(Vec::new());

        assert!(result.should_stop());
    }
}
