//! Secure-store boundary for MLS anti-rollback.
//!
//! The engine deliberately does not implement this with a regular file next
//! to SQLCipher. Platform hosts must provide a monotonic secure-store anchor.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MlsRecoveryState {
    Ready,
    RePairRequired,
}

pub trait MlsEpochAnchor {
    type Error;

    fn highest_epoch(&self, conversation_id: &str) -> Result<Option<u64>, Self::Error>;
    fn record_epoch(&mut self, conversation_id: &str, epoch: u64) -> Result<(), Self::Error>;
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
}
