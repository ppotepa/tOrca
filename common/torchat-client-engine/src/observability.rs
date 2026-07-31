use uuid::Uuid;

use crate::{CommandRouter, EngineCommandEnvelope, OperationContext};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EngineComponent {
    CommandRouter,
    StateActor,
    DeliveryScheduler,
    RelayWorker,
    PeerWorker,
    InboundPipeline,
    PairingProcess,
    ReconnectProcess,
    ProjectionWorker,
    NotificationWorker,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperationEventKind {
    CommandReceived,
    CommandCommitted,
    DeliveryJobCreated,
    RouteSelected,
    AttemptStarted,
    AttemptOutcome,
    RetryScheduled,
    InboundDeduplicated,
    DomainEventCommitted,
    SnapshotPatched,
    CommandCompleted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandMetadata {
    pub command_id: Uuid,
    pub correlation_id: Uuid,
    pub causation_id: Option<Uuid>,
}

impl CommandMetadata {
    pub fn root() -> Self {
        let command_id = Uuid::new_v4();
        Self {
            command_id,
            correlation_id: command_id,
            causation_id: None,
        }
    }

    pub fn caused_by(correlation_id: Uuid, causation_id: Uuid) -> Self {
        Self {
            command_id: Uuid::new_v4(),
            correlation_id,
            causation_id: Some(causation_id),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ObservedCommandEnvelope {
    pub envelope: EngineCommandEnvelope,
    pub metadata: CommandMetadata,
}

impl ObservedCommandEnvelope {
    pub fn from_legacy(envelope: EngineCommandEnvelope) -> Self {
        Self {
            envelope,
            metadata: CommandMetadata::root(),
        }
    }

    pub fn command_type(&self) -> String {
        format!("{:?}", CommandRouter::route(&self.envelope.command).family)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineOperationLog {
    pub operation_id: Uuid,
    pub correlation_id: Uuid,
    pub causation_id: Option<Uuid>,
    pub request_id: String,
    pub generation: u64,
    pub component: EngineComponent,
    pub event: OperationEventKind,
    pub detail_code: Option<String>,
}

impl EngineOperationLog {
    pub fn from_context(
        context: &OperationContext,
        component: EngineComponent,
        event: OperationEventKind,
        detail_code: Option<String>,
    ) -> Self {
        Self {
            operation_id: context.operation_id,
            correlation_id: context.correlation_id,
            causation_id: context.causation_id,
            request_id: context.request_id.clone(),
            generation: context.generation,
            component,
            event,
            detail_code,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EngineMetricsSnapshot {
    pub delivery_due_count: usize,
    pub oldest_delivery_age_ms: i64,
    pub relay_reconnect_attempt: u32,
    pub peer_circuit_open_count: usize,
    pub inbound_duplicate_count: u64,
    pub command_latency_ms: u64,
    pub delivery_latency_ms: u64,
    pub projection_lag: usize,
}

#[cfg(test)]
mod tests {
    use crate::EngineCommand;

    use super::*;

    #[test]
    fn legacy_command_receives_stable_root_correlation() {
        let observed = ObservedCommandEnvelope::from_legacy(EngineCommandEnvelope {
            request_id: "request".to_owned(),
            command: EngineCommand::ListContacts,
        });

        assert_eq!(
            observed.metadata.command_id,
            observed.metadata.correlation_id
        );
        assert_eq!(observed.metadata.causation_id, None);
        assert_eq!(observed.command_type(), "Contacts");
    }

    #[test]
    fn structured_log_contains_codes_not_payload_fields() {
        let context = OperationContext::for_request("request", 7, 10);
        let log = EngineOperationLog::from_context(
            &context,
            EngineComponent::DeliveryScheduler,
            OperationEventKind::RouteSelected,
            Some("peer_verified_endpoint".to_owned()),
        );

        assert_eq!(log.correlation_id, context.correlation_id);
        assert_eq!(log.detail_code.as_deref(), Some("peer_verified_endpoint"));
    }
}
