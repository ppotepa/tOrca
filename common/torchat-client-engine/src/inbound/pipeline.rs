use crate::EngineResult;

use super::{
    DedupDecision, InboundDedupKey, InboundDeduplicator, InboundEnvelope, InboundValidator,
    ValidatedInbound,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcknowledgementPlan {
    pub envelope_id: String,
    pub recipient_id: String,
    pub replay_only: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InboundPreparation {
    Apply {
        validated: ValidatedInbound,
        dedup_key: InboundDedupKey,
        acknowledgement: AcknowledgementPlan,
    },
    DuplicateCommitted,
    ReplayAcknowledgement(AcknowledgementPlan),
}

pub struct InboundPipeline<D, V> {
    deduplicator: D,
    validator: V,
}

impl<D, V> InboundPipeline<D, V>
where
    D: InboundDeduplicator,
    V: InboundValidator,
{
    pub fn new(deduplicator: D, validator: V) -> Self {
        Self {
            deduplicator,
            validator,
        }
    }

    pub fn prepare(&mut self, envelope: InboundEnvelope) -> EngineResult<InboundPreparation> {
        let validated = self.validator.validate(envelope)?;
        let dedup_key = InboundDedupKey::from(&validated.envelope);
        let acknowledgement = AcknowledgementPlan {
            envelope_id: validated.envelope.envelope_id.clone(),
            recipient_id: validated.envelope.sender_id.clone(),
            replay_only: false,
        };

        Ok(match self.deduplicator.inspect(&dedup_key) {
            DedupDecision::New => InboundPreparation::Apply {
                validated,
                dedup_key,
                acknowledgement,
            },
            DedupDecision::DuplicateCommitted => InboundPreparation::DuplicateCommitted,
            DedupDecision::DuplicateNeedsAcknowledgement => {
                InboundPreparation::ReplayAcknowledgement(AcknowledgementPlan {
                    replay_only: true,
                    ..acknowledgement
                })
            }
        })
    }

    pub fn mark_committed(
        &mut self,
        dedup_key: InboundDedupKey,
        acknowledgement_committed: bool,
    ) {
        self.deduplicator
            .mark_committed(dedup_key, acknowledgement_committed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbound::{
        deduplicator::testing::MemoryInboundDeduplicator, BasicInboundValidator,
        InboundTransport, TransportMetadata,
    };

    fn envelope() -> InboundEnvelope {
        InboundEnvelope {
            transport: InboundTransport::Relay,
            envelope_id: "envelope-1".to_owned(),
            sender_id: "peer-1".to_owned(),
            recipient_id: "local".to_owned(),
            protocol_version: 1,
            payload_kind: "message".to_owned(),
            received_at_ms: 10,
            ciphertext: vec![1, 2, 3],
            metadata: TransportMetadata::default(),
        }
    }

    #[test]
    fn duplicate_after_domain_commit_does_not_apply_twice() {
        let mut pipeline = InboundPipeline::new(
            MemoryInboundDeduplicator::default(),
            BasicInboundValidator {
                supported_protocol: 1,
            },
        );
        let first = pipeline.prepare(envelope()).unwrap();
        let InboundPreparation::Apply { dedup_key, .. } = first else {
            panic!("expected apply")
        };
        pipeline.mark_committed(dedup_key, true);

        assert_eq!(
            pipeline.prepare(envelope()).unwrap(),
            InboundPreparation::DuplicateCommitted,
        );
    }

    #[test]
    fn crash_after_commit_before_ack_replays_only_acknowledgement() {
        let mut pipeline = InboundPipeline::new(
            MemoryInboundDeduplicator::default(),
            BasicInboundValidator {
                supported_protocol: 1,
            },
        );
        let first = pipeline.prepare(envelope()).unwrap();
        let InboundPreparation::Apply { dedup_key, .. } = first else {
            panic!("expected apply")
        };
        pipeline.mark_committed(dedup_key, false);

        assert!(matches!(
            pipeline.prepare(envelope()).unwrap(),
            InboundPreparation::ReplayAcknowledgement(AcknowledgementPlan {
                replay_only: true,
                ..
            })
        ));
    }
}
