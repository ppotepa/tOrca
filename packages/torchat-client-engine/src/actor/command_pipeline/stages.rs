#[derive(Debug, Clone, Copy, Eq, PartialEq, Ord, PartialOrd)]
pub enum CommandPipelineStage {
    Validate,
    EnforceCommandId,
    CheckIdempotency,
    OpenTransaction,
    Execute,
    Persist,
    CollectChanges,
    Commit,
    ScheduleEffects,
    PublishRevision,
    EncodeResponse,
}

pub const COMMAND_PIPELINE_ORDER: [CommandPipelineStage; 11] = [
    CommandPipelineStage::Validate,
    CommandPipelineStage::EnforceCommandId,
    CommandPipelineStage::CheckIdempotency,
    CommandPipelineStage::OpenTransaction,
    CommandPipelineStage::Execute,
    CommandPipelineStage::Persist,
    CommandPipelineStage::CollectChanges,
    CommandPipelineStage::Commit,
    CommandPipelineStage::ScheduleEffects,
    CommandPipelineStage::PublishRevision,
    CommandPipelineStage::EncodeResponse,
];

#[derive(Debug, Default)]
pub struct CommandPipelineTrace {
    completed: Vec<CommandPipelineStage>,
}

impl CommandPipelineTrace {
    pub fn complete(&mut self, stage: CommandPipelineStage) {
        if let Some(previous) = self.completed.last().copied() {
            assert!(
                previous < stage,
                "command pipeline stages must be monotonic: {previous:?} -> {stage:?}"
            );
        }
        assert!(
            COMMAND_PIPELINE_ORDER.contains(&stage),
            "unknown command pipeline stage: {stage:?}"
        );
        self.completed.push(stage);
    }

    pub fn completed(&self) -> &[CommandPipelineStage] {
        &self.completed
    }

    pub fn reached(&self, stage: CommandPipelineStage) -> bool {
        self.completed.binary_search(&stage).is_ok()
    }
}
