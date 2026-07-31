use uuid::Uuid;

use crate::EngineResult;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessedCommandRecord {
    pub command_id: Uuid,
    pub command_type: String,
    pub response_json: String,
    pub completed_at_ms: i64,
}

pub trait ProcessedCommandRepository {
    fn load_processed_command(
        &self,
        command_id: Uuid,
    ) -> EngineResult<Option<ProcessedCommandRecord>>;

    fn save_processed_command(
        &mut self,
        record: &ProcessedCommandRecord,
    ) -> EngineResult<()>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IdempotencyDecision {
    Execute,
    Replay(ProcessedCommandRecord),
}

pub struct CommandIdempotency;

impl CommandIdempotency {
    pub fn decide<R: ProcessedCommandRepository>(
        repository: &R,
        command_id: Uuid,
    ) -> EngineResult<IdempotencyDecision> {
        Ok(match repository.load_processed_command(command_id)? {
            Some(record) => IdempotencyDecision::Replay(record),
            None => IdempotencyDecision::Execute,
        })
    }

    pub fn complete<R: ProcessedCommandRepository>(
        repository: &mut R,
        record: ProcessedCommandRecord,
    ) -> EngineResult<()> {
        repository.save_processed_command(&record)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[derive(Default)]
    struct MemoryRepository {
        records: HashMap<Uuid, ProcessedCommandRecord>,
    }

    impl ProcessedCommandRepository for MemoryRepository {
        fn load_processed_command(
            &self,
            command_id: Uuid,
        ) -> EngineResult<Option<ProcessedCommandRecord>> {
            Ok(self.records.get(&command_id).cloned())
        }

        fn save_processed_command(
            &mut self,
            record: &ProcessedCommandRecord,
        ) -> EngineResult<()> {
            self.records
                .entry(record.command_id)
                .or_insert_with(|| record.clone());
            Ok(())
        }
    }

    #[test]
    fn completed_command_is_replayed_instead_of_executed_twice() {
        let command_id = Uuid::new_v4();
        let mut repository = MemoryRepository::default();
        CommandIdempotency::complete(
            &mut repository,
            ProcessedCommandRecord {
                command_id,
                command_type: "send_message".to_owned(),
                response_json: "{\"status\":\"ok\"}".to_owned(),
                completed_at_ms: 10,
            },
        )
        .unwrap();

        assert!(matches!(
            CommandIdempotency::decide(&repository, command_id).unwrap(),
            IdempotencyDecision::Replay(ProcessedCommandRecord {
                completed_at_ms: 10,
                ..
            })
        ));
    }
}
