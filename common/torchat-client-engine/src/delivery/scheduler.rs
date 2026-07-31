use uuid::Uuid;

use super::{
    DeliveryJob, RoutingContext, RoutingDecision, TransportRouter,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeliveryAttempt {
    pub attempt_id: Uuid,
    pub job_id: Uuid,
    pub lease_generation: u64,
    pub route: RoutingDecision,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SchedulerDecision {
    Attempt(DeliveryAttempt),
    Deferred(RoutingDecision),
    PermanentlyFailed { reason: String },
    NotDue,
}

#[derive(Default)]
pub struct DeliveryScheduler {
    lease_generation: u64,
}

impl DeliveryScheduler {
    pub fn plan(
        &mut self,
        job: &DeliveryJob,
        context: &RoutingContext,
        now_ms: i64,
    ) -> SchedulerDecision {
        if !job.due(now_ms) {
            return SchedulerDecision::NotDue;
        }

        let route = TransportRouter::route(context);
        match route {
            RoutingDecision::Peer
            | RoutingDecision::Relay
            | RoutingDecision::PeerThenRelay { .. } => {
                self.lease_generation = self.lease_generation.saturating_add(1);
                SchedulerDecision::Attempt(DeliveryAttempt {
                    attempt_id: Uuid::new_v4(),
                    job_id: job.job_id,
                    lease_generation: self.lease_generation,
                    route,
                })
            }
            RoutingDecision::PermanentFailure { reason } => {
                SchedulerDecision::PermanentlyFailed { reason }
            }
            decision @ (RoutingDecision::WaitForPeerEndpoint
            | RoutingDecision::WaitForNetwork) => SchedulerDecision::Deferred(decision),
        }
    }
}

#[cfg(test)]
mod tests {
    use torchat_client_runtime::{
        ContactTransportPolicy, PeerConnectionStatus, PeerEndpointStatus,
    };

    use super::*;
    use crate::delivery::{
        AggregateType, DeliveryDurability, DeliveryJobState, DeliveryKind,
    };

    fn job() -> DeliveryJob {
        DeliveryJob {
            job_id: Uuid::from_u128(1),
            idempotency_key: "message:1".to_owned(),
            aggregate_type: AggregateType::Message,
            aggregate_id: "message-1".to_owned(),
            kind: DeliveryKind::Message,
            recipient_id: "peer-1".to_owned(),
            payload_reference: "message-1".to_owned(),
            durability: DeliveryDurability::Persistent,
            state: DeliveryJobState::Queued,
            selected_route: None,
            attempt_count: 0,
            next_attempt_at: 10,
            ack_deadline: None,
            last_error: None,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn context() -> RoutingContext {
        RoutingContext {
            policy: ContactTransportPolicy::PeerWithRelayFallback,
            peer_endpoint: PeerEndpointStatus::Verified,
            peer_connection: PeerConnectionStatus::Connected,
            relay_available: true,
            network_online: true,
            delivery_kind: DeliveryKind::Message,
            attempt_count: 0,
        }
    }

    #[test]
    fn scheduler_ignores_jobs_before_their_deadline() {
        let mut scheduler = DeliveryScheduler::default();
        assert_eq!(
            scheduler.plan(&job(), &context(), 9),
            SchedulerDecision::NotDue,
        );
    }

    #[test]
    fn scheduler_assigns_monotonic_lease_generations() {
        let mut scheduler = DeliveryScheduler::default();
        let first = scheduler.plan(&job(), &context(), 10);
        let second = scheduler.plan(&job(), &context(), 10);

        let SchedulerDecision::Attempt(first) = first else {
            panic!("expected first attempt")
        };
        let SchedulerDecision::Attempt(second) = second else {
            panic!("expected second attempt")
        };
        assert!(second.lease_generation > first.lease_generation);
    }
}
