use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperationSource {
    UserCommand,
    RelayEvent,
    PeerEvent,
    RetryScheduler,
    Recovery,
    PlatformFact,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OperationContext {
    pub operation_id: Uuid,
    pub correlation_id: Uuid,
    pub causation_id: Option<Uuid>,
    pub request_id: String,
    pub generation: u64,
    pub started_at_ms: i64,
    pub source: OperationSource,
}

impl OperationContext {
    pub fn for_request(
        request_id: impl Into<String>,
        generation: u64,
        started_at_ms: i64,
    ) -> Self {
        let operation_id = Uuid::new_v4();
        Self {
            operation_id,
            correlation_id: operation_id,
            causation_id: None,
            request_id: request_id.into(),
            generation,
            started_at_ms,
            source: OperationSource::UserCommand,
        }
    }

    pub fn caused_by(
        request_id: impl Into<String>,
        correlation_id: Uuid,
        causation_id: Uuid,
        generation: u64,
        started_at_ms: i64,
        source: OperationSource,
    ) -> Self {
        Self {
            operation_id: Uuid::new_v4(),
            correlation_id,
            causation_id: Some(causation_id),
            request_id: request_id.into(),
            generation,
            started_at_ms,
            source,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_request_uses_operation_id_as_correlation_id() {
        let context = OperationContext::for_request("request-1", 2, 3);
        assert_eq!(context.operation_id, context.correlation_id);
        assert_eq!(context.causation_id, None);
        assert_eq!(context.generation, 2);
    }
}
