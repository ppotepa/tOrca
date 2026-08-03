use crate::EngineError;

/// Deterministic failure boundaries used by crash-recovery tests.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FaultPoint {
    BeforeLocalCommit,
    AfterLocalCommitBeforeDispatch,
    AfterPersistedBeforeDelivered,
    AfterMlsSnapshotBeforeOutbox,
    AfterOutboxBeforeMlsAnchor,
    AfterMlsAnchorBeforeSqlCommit,
    AfterSqlCommitBeforeAnchorFinalize,
    AfterRelayForwarded,
    AfterPeerPersistedAck,
    AfterPeerDeliveredAck,
    BeforeRelationshipRemovalAck,
    AfterDatabaseRekeyBeforeVaultPromote,
}

pub trait FaultInjector: Send + Sync {
    fn hit(&self, point: FaultPoint) -> Result<(), EngineError>;
}

#[derive(Debug, Default)]
pub struct NoopFaultInjector;

impl FaultInjector for NoopFaultInjector {
    fn hit(&self, _point: FaultPoint) -> Result<(), EngineError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct AbortAt(FaultPoint);

    impl FaultInjector for AbortAt {
        fn hit(&self, point: FaultPoint) -> Result<(), EngineError> {
            if point == self.0 {
                Err(EngineError::Storage("fault injection".to_owned()))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn noop_injector_preserves_production_shape() {
        let injector = NoopFaultInjector;
        assert!(injector.hit(FaultPoint::BeforeLocalCommit).is_ok());
        assert!(
            injector
                .hit(FaultPoint::AfterLocalCommitBeforeDispatch)
                .is_ok()
        );
    }

    #[test]
    fn injected_failure_hits_only_the_requested_boundary() {
        let injector = AbortAt(FaultPoint::AfterLocalCommitBeforeDispatch);
        assert!(injector.hit(FaultPoint::BeforeLocalCommit).is_ok());
        assert!(
            injector
                .hit(FaultPoint::AfterLocalCommitBeforeDispatch)
                .is_err()
        );
    }
}
