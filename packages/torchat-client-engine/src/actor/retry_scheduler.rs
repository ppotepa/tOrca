use super::*;

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

fn monotonic_wakeup_at(deadline_at_ms: i64, wall_now_ms: i64, monotonic_now: Instant) -> Instant {
    let delay_ms = deadline_at_ms
        .checked_sub(wall_now_ms)
        .filter(|delay| *delay > 0)
        .unwrap_or_default() as u64;
    monotonic_now + Duration::from_millis(delay_ms)
}

#[cfg(test)]
mod tests {
    use super::monotonic_wakeup_at;
    use tokio::time::{Duration, Instant};

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
}
