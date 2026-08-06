use serde::{Deserialize, Serialize};

use crate::{OperationId, RuntimeErrorCode};

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationType {
    Pairing,
    PairingCancellation,
    MessageDelivery,
    RelationshipRemoval,
    EndpointRotation,
    ProfileReset,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationState {
    Pending,
    Running,
    WaitingForRetry,
    Completed,
    Cancelled,
    FailedPermanent,
}

impl OperationState {
    pub const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Cancelled | Self::FailedPermanent
        )
    }
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DurableOperation {
    pub operation_id: OperationId,
    pub operation_type: OperationType,
    pub entity_id: String,
    pub state: OperationState,
    pub started_at: i64,
    pub updated_at: i64,
    pub attempt_count: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<RuntimeErrorCode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_descriptor: Option<String>,
}

impl DurableOperation {
    pub fn pending(
        operation_id: OperationId,
        operation_type: OperationType,
        entity_id: impl Into<String>,
        now_ms: i64,
    ) -> Self {
        Self {
            operation_id,
            operation_type,
            entity_id: entity_id.into(),
            state: OperationState::Pending,
            started_at: now_ms,
            updated_at: now_ms,
            attempt_count: 0,
            retry_at: None,
            error_code: None,
            command_descriptor: None,
        }
    }

    pub fn with_command_descriptor(mut self, descriptor: impl Into<String>) -> Self {
        self.command_descriptor = Some(descriptor.into());
        self
    }

    pub fn begin_attempt(&mut self, now_ms: i64) {
        self.state = OperationState::Running;
        self.updated_at = now_ms;
        self.attempt_count = self.attempt_count.saturating_add(1);
        self.retry_at = None;
        self.error_code = None;
    }

    pub fn schedule_retry(
        &mut self,
        retry_at: i64,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) {
        self.state = OperationState::WaitingForRetry;
        self.updated_at = now_ms;
        self.retry_at = Some(retry_at);
        self.error_code = Some(error_code);
    }

    pub fn complete(&mut self, now_ms: i64) {
        self.state = OperationState::Completed;
        self.updated_at = now_ms;
        self.retry_at = None;
        self.error_code = None;
    }

    pub fn fail_permanently(&mut self, error_code: RuntimeErrorCode, now_ms: i64) {
        self.state = OperationState::FailedPermanent;
        self.updated_at = now_ms;
        self.retry_at = None;
        self.error_code = Some(error_code);
    }
}
