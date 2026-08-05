use crate::{
    EngineEvent,
    effects::EngineEffectEnvelope,
    input::EngineInputEnvelope,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ProcessingControl {
    Continue,
    Stop,
}

pub(crate) struct EngineProcessingResult {
    pub events: Vec<EngineEvent>,
    pub effects: Vec<EngineEffectEnvelope>,
    pub derived_inputs: Vec<EngineInputEnvelope>,
    pub scheduler_plan_changed: bool,
    pub control: ProcessingControl,
}

impl EngineProcessingResult {
    pub(crate) fn empty() -> Self {
        Self {
            events: Vec::new(),
            effects: Vec::new(),
            derived_inputs: Vec::new(),
            scheduler_plan_changed: false,
            control: ProcessingControl::Continue,
        }
    }

    pub(crate) fn stop(events: Vec<EngineEvent>) -> Self {
        Self {
            events,
            effects: Vec::new(),
            derived_inputs: Vec::new(),
            scheduler_plan_changed: false,
            control: ProcessingControl::Stop,
        }
    }

    pub(crate) fn should_stop(&self) -> bool {
        self.control == ProcessingControl::Stop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_result_continues_without_outputs() {
        let result = EngineProcessingResult::empty();

        assert!(result.events.is_empty());
        assert!(result.effects.is_empty());
        assert!(result.derived_inputs.is_empty());
        assert!(!result.scheduler_plan_changed);
        assert!(!result.should_stop());
    }

    #[test]
    fn stop_result_has_explicit_control() {
        let result = EngineProcessingResult::stop(Vec::new());

        assert!(result.should_stop());
    }
}
