use super::*;

impl ClientEngineActor {
    pub(super) async fn run_retry_scheduler(
        &mut self,
        events: &mpsc::Sender<EngineEvent>,
        deadline: RetryDeadline,
    ) {
        if !self.retry_is_runnable(deadline.kind) {
            return;
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
            RetryKind::PeerEndpointBootstrap => self
                .retry_peer_endpoint_bootstraps()
                .map(|_| "peer endpoint bootstrap flush"),
            RetryKind::ContactConfirmation => self
                .retry_pending_contact_confirmations()
                .map(|_| "contact confirmation flush"),
            RetryKind::PairingAcknowledgement => self
                .retry_pending_pairing_acknowledgements()
                .map(|_| "pairing acknowledgement flush"),
        };
        if let Err(error) = result {
            let _ = events
                .send(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "retry scheduler {:?} failed at {}: {error}",
                            deadline.kind, deadline.at_ms
                        ),
                    },
                })
                .await;
        }
    }

    pub(super) fn next_retry_deadline(&self) -> EngineResult<Option<RetryDeadline>> {
        self.database
            .next_retry_deadline(unix_ms(), self.clock.now_secs())
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
        let retry_delay_ms = retry_deadline.at_ms.saturating_sub(unix_ms()) as u64;
        Ok(Some(Instant::now() + Duration::from_millis(retry_delay_ms)))
    }

    fn retry_is_runnable(&self, kind: RetryKind) -> bool {
        let control_plane_required = matches!(
            kind,
            RetryKind::PairingResponse
                | RetryKind::PendingWelcome
                | RetryKind::PeerEndpointBootstrap
                | RetryKind::ContactConfirmation
        );
        if control_plane_required {
            return self.network_online
                && self.socks5_url.is_some()
                && self.connection_state == ConnectionState::Connected;
        }
        self.network_online && self.socks5_url.is_some()
    }

    fn retry_expired_ack_deadlines(&mut self) -> EngineResult<()> {
        for message_id in self.database.expired_ack_deadline_message_ids(unix_ms())? {
            let _ = self.apply_message_transport_outcome(
                &message_id,
                MessageTransportOutcome::RetryableFailure,
            )?;
        }
        Ok(())
    }
}
