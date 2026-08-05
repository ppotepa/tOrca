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

pub(crate) struct EngineProcessingResultBuilder {
    result: EngineProcessingResult,
}

impl EngineProcessingResultBuilder {
    pub(crate) fn new() -> Self {
        Self {
            result: EngineProcessingResult::empty(),
        }
    }

    pub(crate) fn event(mut self, event: EngineEvent) -> Self {
        self.result.events.push(event);
        self
    }

    pub(crate) fn events(mut self, events: impl IntoIterator<Item = EngineEvent>) -> Self {
        self.result.events.extend(events);
        self
    }

    pub(crate) fn effect(mut self, effect: EngineEffectEnvelope) -> Self {
        self.result.effects.push(effect);
        self
    }

    pub(crate) fn effects(
        mut self,
        effects: impl IntoIterator<Item = EngineEffectEnvelope>,
    ) -> Self {
        self.result.effects.extend(effects);
        self
    }

    pub(crate) fn derived_input(mut self, input: EngineInputEnvelope) -> Self {
        self.result.derived_inputs.push(input);
        self
    }

    pub(crate) fn scheduler_plan_changed(mut self) -> Self {
        self.result.scheduler_plan_changed = true;
        self
    }

    pub(crate) fn stop(mut self) -> Self {
        self.result.control = ProcessingControl::Stop;
        self
    }

    pub(crate) fn build(self) -> EngineProcessingResult {
        self.result
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
    fn builder_marks_stop_explicitly() {
        let result = EngineProcessingResultBuilder::new().stop().build();

        assert!(result.should_stop());
    }
}
