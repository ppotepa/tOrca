use uuid::Uuid;

use crate::OutboundDeliveryRecord;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AggregateType {
    Message,
    Pairing,
    Receipt,
    PeerEndpoint,
    ContactConfirmation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryKind {
    Message,
    Receipt,
    PairingOffer,
    PairingRejection,
    Welcome,
    ContactConfirmation,
    PeerEndpointBootstrap,
    PeerEndpointUpdate,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryDurability {
    Persistent,
    Ephemeral,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectedRoute {
    Peer,
    Relay,
    PeerThenRelay,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryJobState {
    Queued,
    Attempting,
    AwaitingAcknowledgement,
    Delivered,
    RetryScheduled,
    PermanentlyFailed,
    Cancelled,
}

impl DeliveryJobState {
    pub fn from_legacy(value: &str) -> Self {
        match value.trim().to_ascii_uppercase().as_str() {
            "SENDING" | "ATTEMPTING" => Self::Attempting,
            "SENT" | "AWAITING_ACK" => Self::AwaitingAcknowledgement,
            "DELIVERED" | "READ" => Self::Delivered,
            "FAILED" | "PERMANENTLY_FAILED" => Self::PermanentlyFailed,
            "CANCELLED" => Self::Cancelled,
            "RETRY_SCHEDULED" => Self::RetryScheduled,
            _ => Self::Queued,
        }
    }

    pub const fn terminal(self) -> bool {
        matches!(
            self,
            Self::Delivered | Self::PermanentlyFailed | Self::Cancelled
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeliveryJob {
    pub job_id: Uuid,
    pub idempotency_key: String,
    pub aggregate_type: AggregateType,
    pub aggregate_id: String,
    pub kind: DeliveryKind,
    pub recipient_id: String,
    pub payload_reference: String,
    pub durability: DeliveryDurability,
    pub state: DeliveryJobState,
    pub selected_route: Option<SelectedRoute>,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl DeliveryJob {
    pub fn from_legacy_message(
        record: &OutboundDeliveryRecord,
        job_id: Uuid,
        payload_reference: impl Into<String>,
    ) -> Self {
        Self {
            job_id,
            idempotency_key: format!("message:{}", record.message_id),
            aggregate_type: AggregateType::Message,
            aggregate_id: record.message_id.clone(),
            kind: DeliveryKind::Message,
            recipient_id: record.contact_installation_id.clone(),
            payload_reference: payload_reference.into(),
            durability: DeliveryDurability::Persistent,
            state: DeliveryJobState::from_legacy(&record.state),
            selected_route: None,
            attempt_count: record.attempt_count,
            next_attempt_at: record.next_attempt_at,
            ack_deadline: record.ack_deadline,
            last_error: record.last_error.clone(),
            created_at: record.created_at,
            updated_at: record.created_at,
        }
    }

    pub const fn due(&self, now_ms: i64) -> bool {
        !self.state.terminal() && self.next_attempt_at <= now_ms
    }

    pub fn schedule_retry(&mut self, retry_at: i64, error: impl Into<String>) {
        self.state = DeliveryJobState::RetryScheduled;
        self.next_attempt_at = retry_at;
        self.last_error = Some(error.into());
        self.updated_at = retry_at;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_message_delivery_maps_to_one_idempotent_job() {
        let record = OutboundDeliveryRecord {
            message_id: "message-1".to_owned(),
            contact_installation_id: "peer-1".to_owned(),
            sequence: 2,
            state: "QUEUED".to_owned(),
            attempt_count: 1,
            next_attempt_at: 10,
            ack_deadline: None,
            last_error: None,
            created_at: 5,
        };
        let job = DeliveryJob::from_legacy_message(
            &record,
            Uuid::from_u128(1),
            "messages/message-1",
        );

        assert_eq!(job.idempotency_key, "message:message-1");
        assert_eq!(job.aggregate_id, "message-1");
        assert_eq!(job.kind, DeliveryKind::Message);
        assert_eq!(job.state, DeliveryJobState::Queued);
        assert!(job.due(10));
    }
}
