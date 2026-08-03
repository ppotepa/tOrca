//! Secure-store boundary for MLS anti-rollback.
//!
//! The engine deliberately does not implement this with a regular file next
//! to SQLCipher. Platform hosts must provide a monotonic secure-store anchor.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MlsRecoveryState {
    Ready,
    RePairRequired,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AnchoredMlsCheckpoint {
    pub state_version: u64,
    pub epoch: u64,
    pub snapshot_hash: Vec<u8>,
}

pub fn validate_checkpoint(
    anchored: Option<&AnchoredMlsCheckpoint>,
    candidate: &AnchoredMlsCheckpoint,
) -> MlsRecoveryState {
    let Some(anchored) = anchored else {
        return MlsRecoveryState::Ready;
    };
    // Epoch-only anchors are the compatibility representation used by hosts
    // that have not migrated their secure store to checkpoint V2 yet.  Do not
    // compare their epoch-derived state_version with the new local counter.
    if anchored.snapshot_hash.is_empty() {
        return if candidate.epoch < anchored.epoch {
            MlsRecoveryState::RePairRequired
        } else {
            MlsRecoveryState::Ready
        };
    }
    if candidate.state_version < anchored.state_version
        || (candidate.state_version == anchored.state_version
            && candidate.snapshot_hash != anchored.snapshot_hash)
    {
        MlsRecoveryState::RePairRequired
    } else {
        MlsRecoveryState::Ready
    }
}

pub trait MlsEpochAnchor {
    type Error;

    fn highest_epoch(&self, conversation_id: &str) -> Result<Option<u64>, Self::Error>;
    fn record_epoch(&mut self, conversation_id: &str, epoch: u64) -> Result<(), Self::Error>;

    fn highest_checkpoint(
        &self,
        conversation_id: &str,
    ) -> Result<Option<AnchoredMlsCheckpoint>, Self::Error> {
        Ok(self
            .highest_epoch(conversation_id)?
            .map(|epoch| AnchoredMlsCheckpoint {
                state_version: epoch,
                epoch,
                snapshot_hash: Vec::new(),
            }))
    }

    fn record_checkpoint(
        &mut self,
        conversation_id: &str,
        checkpoint: &AnchoredMlsCheckpoint,
    ) -> Result<(), Self::Error> {
        self.record_epoch(conversation_id, checkpoint.epoch)
    }
}

pub fn validate_snapshot_checkpoint<A: MlsEpochAnchor + ?Sized>(
    anchor: &mut A,
    conversation_id: &str,
    candidate: &AnchoredMlsCheckpoint,
) -> Result<MlsRecoveryState, A::Error> {
    let anchored = anchor.highest_checkpoint(conversation_id)?;
    if validate_checkpoint(anchored.as_ref(), candidate) == MlsRecoveryState::RePairRequired {
        return Ok(MlsRecoveryState::RePairRequired);
    }
    anchor.record_checkpoint(conversation_id, candidate)?;
    Ok(MlsRecoveryState::Ready)
}

pub fn validate_snapshot_epoch<A: MlsEpochAnchor + ?Sized>(
    anchor: &mut A,
    conversation_id: &str,
    snapshot_epoch: u64,
) -> Result<MlsRecoveryState, A::Error> {
    let stored = anchor.highest_epoch(conversation_id)?;
    if stored.is_some_and(|epoch| snapshot_epoch < epoch) {
        return Ok(MlsRecoveryState::RePairRequired);
    }
    anchor.record_epoch(conversation_id, snapshot_epoch)?;
    Ok(MlsRecoveryState::Ready)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct MemoryAnchor(HashMap<String, u64>);

    impl MlsEpochAnchor for MemoryAnchor {
        type Error = &'static str;

        fn highest_epoch(&self, id: &str) -> Result<Option<u64>, Self::Error> {
            Ok(self.0.get(id).copied())
        }

        fn record_epoch(&mut self, id: &str, epoch: u64) -> Result<(), Self::Error> {
            self.0.insert(id.to_owned(), epoch);
            Ok(())
        }
    }

    #[test]
    fn current_or_newer_snapshot_advances_anchor() {
        let mut anchor = MemoryAnchor::default();
        assert_eq!(
            validate_snapshot_epoch(&mut anchor, "conversation", 4).unwrap(),
            MlsRecoveryState::Ready
        );
        assert_eq!(
            validate_snapshot_epoch(&mut anchor, "conversation", 4).unwrap(),
            MlsRecoveryState::Ready
        );
        assert_eq!(anchor.0["conversation"], 4);
        assert_eq!(
            validate_snapshot_epoch(&mut anchor, "conversation", 5).unwrap(),
            MlsRecoveryState::Ready
        );
        assert_eq!(anchor.0["conversation"], 5);
    }

    #[test]
    fn older_snapshot_requires_repair_and_does_not_lower_anchor() {
        let mut anchor = MemoryAnchor::default();
        validate_snapshot_epoch(&mut anchor, "conversation", 8).unwrap();
        assert_eq!(
            validate_snapshot_epoch(&mut anchor, "conversation", 7).unwrap(),
            MlsRecoveryState::RePairRequired
        );
        assert_eq!(anchor.0["conversation"], 8);
    }

    #[test]
    fn same_epoch_snapshot_rollback_is_detected_by_state_version_and_hash() {
        let anchored = AnchoredMlsCheckpoint {
            state_version: 4,
            epoch: 9,
            snapshot_hash: vec![4; 32],
        };
        assert_eq!(
            validate_checkpoint(
                Some(&anchored),
                &AnchoredMlsCheckpoint {
                    state_version: 3,
                    epoch: 9,
                    snapshot_hash: vec![3; 32],
                },
            ),
            MlsRecoveryState::RePairRequired
        );
        assert_eq!(
            validate_checkpoint(
                Some(&anchored),
                &AnchoredMlsCheckpoint {
                    state_version: 4,
                    epoch: 9,
                    snapshot_hash: vec![5; 32],
                },
            ),
            MlsRecoveryState::RePairRequired
        );
    }
}
