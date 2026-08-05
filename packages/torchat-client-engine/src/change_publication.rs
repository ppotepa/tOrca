use torchat_runtime::{ChangePublisher, CommittedChange, DomainEffect, FeatureResult};

#[derive(Debug, Default)]
pub struct ChangePublication {
    publisher: ChangePublisher,
}

impl ChangePublication {
    pub const fn new(revision: u64) -> Self {
        Self {
            publisher: ChangePublisher::new(revision),
        }
    }

    pub const fn revision(&self) -> u64 {
        self.publisher.revision()
    }

    /// Persistence is committed before the revision is advanced. The returned
    /// effects are intentionally not executed while the storage transaction is open.
    pub fn commit<T, E>(
        &mut self,
        result: FeatureResult<T>,
        commit: impl FnOnce() -> Result<(), E>,
    ) -> Result<CommittedChange<T>, E> {
        self.publisher.commit(result, commit)
    }

    pub fn schedule_effects<T>(
        committed: &CommittedChange<T>,
        mut schedule: impl FnMut(DomainEffect),
    ) {
        for effect in committed.effects.iter().cloned() {
            schedule(effect);
        }
    }
}
