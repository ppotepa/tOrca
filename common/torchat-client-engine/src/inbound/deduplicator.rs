use super::InboundEnvelope;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct InboundDedupKey(pub String);

impl From<&InboundEnvelope> for InboundDedupKey {
    fn from(envelope: &InboundEnvelope) -> Self {
        Self(envelope.dedup_material())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DedupDecision {
    New,
    DuplicateCommitted,
    DuplicateNeedsAcknowledgement,
}

pub trait InboundDeduplicator {
    fn inspect(&mut self, key: &InboundDedupKey) -> DedupDecision;
    fn mark_committed(&mut self, key: InboundDedupKey, acknowledgement_committed: bool);
}

#[cfg(test)]
pub(crate) mod testing {
    use std::collections::BTreeMap;

    use super::*;

    #[derive(Default)]
    pub struct MemoryInboundDeduplicator {
        committed: BTreeMap<InboundDedupKey, bool>,
    }

    impl InboundDeduplicator for MemoryInboundDeduplicator {
        fn inspect(&mut self, key: &InboundDedupKey) -> DedupDecision {
            match self.committed.get(key) {
                None => DedupDecision::New,
                Some(true) => DedupDecision::DuplicateCommitted,
                Some(false) => DedupDecision::DuplicateNeedsAcknowledgement,
            }
        }

        fn mark_committed(&mut self, key: InboundDedupKey, acknowledgement_committed: bool) {
            self.committed.insert(key, acknowledgement_committed);
        }
    }
}
