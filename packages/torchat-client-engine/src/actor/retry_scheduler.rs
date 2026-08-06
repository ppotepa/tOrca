use super::*;

use crate::{
    effects::{DeferredCommandContext, RelayEffectOperation},
    processing::EngineProcessingResult,
};
use torchat_runtime::{
    ClientRuntimeFeatureFacade, DurableOperation, OperationState, OperationStorage, OperationType,
    RuntimeErrorCode, features::operations::ClientRuntimeOperationsFacade,
};

impl ClientEngineActor {
    pub(super) fn run_retry_scheduler_collect(
        &mut self,
        deadline: RetryDeadline,
    ) -> Vec<EngineEvent> {
        if !self.retry_is_runnable(deadline.kind) {
            return Vec::new();
        }
        let result = match deadline.kind {
            RetryKind::MessageSend | RetryKind::PairingResponse => {
                self.flush_pending_send_effects().map(|_| "send flush")
            }
            RetryKind::MessageAckDeadline => self
                .retry_expired_ack_deadlines()
                .map(|_| "ack deadline handling"),
            RetryKind::Receipt => self
                .flush_pending_receipt_effects()
                .map(|_| "receipt flush"),
            RetryKind::PendingWelcome => self.retry_pending_welcomes().map(|_| "welcome flush"),
            RetryKind::ReadReceipt => self
                .flush_pending_read_receipts()
                .map(|_| "read receipt flush"),
            RetryKind::RelationshipRemoval | RetryKind::RelationshipRemovalAck => self
                .flush_pending_send_effects()
                .map(|_| "relationship removal flush"),
        };
        match result {
            Ok(_) => Vec::new(),
            Err(error) => vec![EngineEvent::Log {
                log: EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "retry scheduler {:?} failed at {}: {error}",
                        deadline.kind, deadline.at_ms
                    ),
                },
            }],
        }
    }

    pub(super) fn next_retry_deadline(&self) -> EngineResult<Option<RetryDeadline>> {
        self.database
            .next_retry_deadline(self.clock.now_ms(), self.clock.now_secs())
    }

    pub(super) fn next_retry_wakeup_at(
        &self,
        retry_deadline: Option<RetryDeadline>,
    ) -> EngineResult<Option<Instant>> {
        let Some(retry_deadline) = retry_deadline else {
            return Ok(None);
        };
        if !self.retry_is_runnable(retry_deadline.kind) {
            // A durable deadline in the past must not turn `sleep_until` into
            // a tight loop while Tor, SOCKS or the relay control plane is
            // unavailable. Platform facts still wake the actor immediately;
            // this is solely a bounded fallback when such a fact is absent.
            let delay = if !self.network_online {
                RETRY_OFFLINE_RECHECK
            } else {
                RETRY_BLOCKED_RECHECK
            };
            return Ok(Some(Instant::now() + delay));
        }
        // Durable retry records use wall-clock milliseconds so they survive a
        // restart. Convert that timestamp once into a process-local monotonic
        // deadline; sleeping must not be affected by a wall-clock jump after
        // this point.
        Ok(Some(monotonic_wakeup_at(
            retry_deadline.at_ms,
            self.clock.now_ms(),
            Instant::now(),
        )))
    }

    pub(super) fn next_durable_operation_wakeup_at(&self) -> EngineResult<Option<Instant>> {
        let deadline_at_ms = self
            .pending_durable_operations()?
            .iter()
            .filter(|operation| {
                operation.operation_type == OperationType::PairingCancellation
            })
            .filter_map(durable_operation_deadline)
            .min();
        let Some(deadline_at_ms) = deadline_at_ms else {
            return Ok(None);
        };
        if !self.network_online || self.socks5_url.is_none() || !self.relay.can_start_effect() {
            let delay = if !self.network_online {
                RETRY_OFFLINE_RECHECK
            } else {
                RETRY_BLOCKED_RECHECK
            };
            return Ok(Some(Instant::now() + delay));
        }
        Ok(Some(monotonic_wakeup_at(
            deadline_at_ms,
            self.clock.now_ms(),
            Instant::now(),
        )))
    }

    pub(super) fn resume_due_durable_operation(
        &mut self,
        causation_id: uuid::Uuid,
    ) -> EngineResult<EngineProcessingResult> {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        if !self.network_online || self.socks5_url.is_none() || !self.relay.can_start_effect() {
            return Ok(result);
        }

        let now_ms = self.clock.now_ms();
        let operation = self
            .pending_durable_operations()?
            .into_iter()
            .filter(|operation| {
                operation.operation_type == OperationType::PairingCancellation
            })
            .find(|operation| {
                durable_operation_deadline(operation).is_some_and(|deadline| deadline <= now_ms)
            });
        let Some(operation) = operation else {
            return Ok(result);
        };

        let operation_id = operation.operation_id.as_str().to_owned();
        let pairing_id = operation.entity_id.clone();
        let Some(command_descriptor) = operation.command_descriptor.clone() else {
            self.with_runtime(|runtime| {
                runtime.feature_fail_pairing_operation(
                    &operation_id,
                    &pairing_id,
                    RuntimeErrorCode::Internal,
                    now_ms,
                )?;
                Ok(())
            })?;
            result.events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "error".to_owned(),
                    message: format!(
                        "durable pairing operation {operation_id} cannot resume without command descriptor"
                    ),
                },
            });
            return Ok(result);
        };

        let (_, mut runtime_events) = self.with_runtime(|runtime| {
            runtime.feature_begin_pairing_operation(
                &operation_id,
                &pairing_id,
                &command_descriptor,
                now_ms,
            )?;
            Ok(())
        })?;

        match self.with_runtime(|runtime| runtime.feature_prepare_cancel_pairing(&pairing_id)) {
            Ok((prepared, mut preparation_events)) => {
                runtime_events.append(&mut preparation_events);
                Ok(self.defer_relay_effect(
                    causation_id,
                    DeferredCommandContext {
                        request_id: format!("__resume__:{operation_id}"),
                        command_id: Some(operation_id),
                        command_descriptor,
                    },
                    RelayEffectOperation::CancelPairing {
                        pairing_id: prepared.pairing_id,
                    },
                    runtime_events,
                ))
            }
            Err(error) => {
                self.record_pairing_cancel_failure(&operation_id, &pairing_id)?;
                result.extend_runtime_events(runtime_events);
                result.events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "durable pairing operation {operation_id} could not prepare retry: {error}"
                        ),
                    },
                });
                Ok(result)
            }
        }
    }

    fn pending_durable_operations(&self) -> EngineResult<Vec<DurableOperation>> {
        OperationStorage::pending_operations(&self.database).map_err(runtime_error)
    }

    fn retry_is_runnable(&self, kind: RetryKind) -> bool {
        let _policy = super::RetryPolicy::for_kind(kind);
        // No retry depends on a globally connected relay. Pairing retries use
        // the short-lived V1 rendezvous connection; messages, receipts and
        // relationship updates use direct peer transport.
        self.network_online && self.socks5_url.is_some()
    }

    fn retry_expired_ack_deadlines(&mut self) -> EngineResult<()> {
        for message_id in self
            .database
            .expired_ack_deadline_message_ids(self.clock.now_ms())?
        {
            let _ = self.apply_message_transport_outcome(
                &message_id,
                MessageTransportOutcome::RetryableFailure,
            )?;
        }
        Ok(())
    }
}

fn durable_operation_deadline(operation: &DurableOperation) -> Option<i64> {
    match operation.state {
        OperationState::Pending | OperationState::Running => Some(operation.updated_at),
        OperationState::WaitingForRetry => Some(operation.retry_at.unwrap_or(operation.updated_at)),
        OperationState::Completed
        | OperationState::Cancelled
        | OperationState::FailedPermanent => None,
    }
}

fn monotonic_wakeup_at(deadline_at_ms: i64, wall_now_ms: i64, monotonic_now: Instant) -> Instant {
    let delay_ms = deadline_at_ms
        .checked_sub(wall_now_ms)
        .filter(|delay| *delay > 0)
        .unwrap_or_default() as u64;
    monotonic_now + Duration::from_millis(delay_ms)
}

#[cfg(test)]
mod tests {
    use super::{durable_operation_deadline, monotonic_wakeup_at};
    use tokio::time::{Duration, Instant};
    use torchat_runtime::{
        DurableOperation, OperationId, OperationState, OperationType, RuntimeErrorCode,
    };

    #[test]
    fn durable_wall_deadline_is_converted_to_monotonic_deadline_once() {
        let now = Instant::now();
        let wakeup = monotonic_wakeup_at(10_500, 10_000, now);
        assert!(wakeup >= now + Duration::from_millis(500));
        assert!(wakeup <= now + Duration::from_millis(501));
    }

    #[test]
    fn wall_clock_rollback_cannot_create_a_negative_duration() {
        let now = Instant::now();
        let wakeup = monotonic_wakeup_at(9_000, 10_000, now);
        assert_eq!(wakeup, now);
    }

    #[test]
    fn waiting_operation_uses_persisted_retry_deadline() {
        let mut operation = DurableOperation::pending(
            OperationId::parse("operation-1").expect("valid id"),
            OperationType::PairingCancellation,
            "pairing-1",
            10_000,
        );
        operation.state = OperationState::WaitingForRetry;
        operation.retry_at = Some(12_500);
        operation.error_code = Some(RuntimeErrorCode::TransportUnavailable);
        assert_eq!(durable_operation_deadline(&operation), Some(12_500));
    }
}
