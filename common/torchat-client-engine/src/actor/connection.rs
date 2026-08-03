use super::*;

fn push_bounded<T>(queue: &mut VecDeque<T>, item: T, limit: usize) -> bool {
    if queue.len() >= limit {
        return false;
    }
    queue.push_back(item);
    true
}

impl ClientEngineActor {
    fn enqueue_relay_control(&mut self, pending: PendingRelayControl) -> bool {
        if !push_bounded(
            &mut self.relay_control_queue,
            pending,
            super::MAX_RELAY_CONTROL_QUEUE,
        ) {
            self.relay_control_rejected = self.relay_control_rejected.saturating_add(1);
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "relay_control_queue_full source=internal depth={} rejected={} coalesced={}",
                        self.relay_control_queue.len(),
                        self.relay_control_rejected,
                        self.relay_control_coalesced
                    ),
                },
            });
            return false;
        }
        true
    }

    fn relay_control_is_queued<F>(&self, predicate: F) -> bool
    where
        F: Fn(&RelayControlOperation) -> bool,
    {
        self.relay_control_queue
            .iter()
            .any(|pending| predicate(&pending.operation))
    }

    pub(super) fn enqueue_pairing_acknowledgement(&mut self, pairing_id: &str) {
        if self.relay_control_is_queued(|operation| {
            matches!(
                operation,
                RelayControlOperation::AcknowledgePairing { pairing_id: queued }
                    if queued == pairing_id
            )
        }) {
            return;
        }
        self.enqueue_relay_control(PendingRelayControl {
            request_id: String::new(),
            respond: false,
            command_id: None,
            command_descriptor: "internal:acknowledge_pairing".to_owned(),
            operation: RelayControlOperation::AcknowledgePairing {
                pairing_id: pairing_id.to_owned(),
            },
        });
        if let Some(sender) = self.relay_control_sender.clone() {
            self.start_next_relay_control(sender);
        }
    }

    pub(super) fn enqueue_contact_confirmation(
        &mut self,
        record: &PendingContactConfirmationRecord,
    ) {
        if self.relay_control_is_queued(|operation| {
            matches!(
                operation,
                RelayControlOperation::ConfirmContact { pairing_id, .. }
                    if pairing_id == &record.pairing_id
            )
        }) {
            return;
        }
        self.enqueue_relay_control(PendingRelayControl {
            request_id: String::new(),
            respond: false,
            command_id: None,
            command_descriptor: "internal:confirm_contact".to_owned(),
            operation: RelayControlOperation::ConfirmContact {
                pairing_id: record.pairing_id.clone(),
                capability: record.capability.clone(),
                peer_installation_id: record.peer_installation_id.clone(),
            },
        });
        if let Some(sender) = self.relay_control_sender.clone() {
            self.start_next_relay_control(sender);
        }
    }

    pub(super) fn enqueue_pairing_inbox_refresh(&mut self) {
        if self.relay_control_is_queued(|operation| {
            matches!(
                operation,
                RelayControlOperation::Command(EngineCommand::PairingInbox)
            )
        }) {
            return;
        }
        self.enqueue_relay_control(PendingRelayControl {
            request_id: String::new(),
            respond: false,
            command_id: None,
            command_descriptor: "internal:pairing_inbox".to_owned(),
            operation: RelayControlOperation::Command(EngineCommand::PairingInbox),
        });
        if let Some(sender) = self.relay_control_sender.clone() {
            self.start_next_relay_control(sender);
        }
    }

    fn schedule_pairing_inbox_retry(&mut self) -> u64 {
        let attempt = self.pairing_inbox_retry_attempt;
        self.pairing_inbox_retry_attempt = attempt.saturating_add(1);
        let retry_in_ms = pairing_retry_backoff_ms(attempt).max(250) as u64;
        self.pairing_inbox_retry_at = Some(Instant::now() + Duration::from_millis(retry_in_ms));
        retry_in_ms
    }

    pub(super) fn start_next_relay_control(&mut self, outcomes: mpsc::Sender<RelayControlOutcome>) {
        if self.relay_control_in_flight || self.relay_control_queue.is_empty() {
            return;
        }
        let Some(pending) = self.relay_control_queue.pop_front() else {
            return;
        };
        self.relay_control_in_flight = true;
        let relay_onion_url = self.relay_onion_url.clone();
        let socks5_url = self.socks5_url.clone();
        let identity = Identity::from_private_key_bytes(self.identity.private_key_bytes());
        tokio::task::spawn_blocking(move || {
            let mut relay = SharedRelayActor::new(relay_onion_url, socks5_url, identity);
            // Control-plane HTTP operations must not create a second event
            // WebSocket. `ensure_session()` starts the long-lived writer and
            // would make the server replace the primary actor connection.
            let result = relay
                .ensure_http_session()
                .and_then(|()| match &pending.operation {
                    RelayControlOperation::Command(EngineCommand::SetNickname { nickname }) => {
                        relay
                            .update_profile(nickname)
                            .map(|()| RelayControlResult::Unit)
                    }
                    RelayControlOperation::Command(EngineCommand::RefreshPairingCode) => relay
                        .refresh_pairing_code()
                        .map(RelayControlResult::PairingCode),
                    RelayControlOperation::Command(EngineCommand::SubmitPairingCode { code }) => {
                        relay
                            .submit_pairing_code(code)
                            .map(|item| RelayControlResult::PairingItem(Box::new(item)))
                    }
                    RelayControlOperation::Command(EngineCommand::PairingInbox) => {
                        relay.pairing_inbox().map(RelayControlResult::PairingInbox)
                    }
                    RelayControlOperation::Command(EngineCommand::CancelPairing { pairing_id }) => {
                        relay
                            .cancel_pairing(pairing_id)
                            .map(|()| RelayControlResult::Unit)
                    }
                    RelayControlOperation::AcknowledgePairing { pairing_id } => relay
                        .acknowledge_pairing(pairing_id)
                        .map(|()| RelayControlResult::Unit),
                    RelayControlOperation::ConfirmContact {
                        capability,
                        peer_installation_id,
                        ..
                    } => relay
                        .confirm_contact(capability, peer_installation_id)
                        .map(|()| RelayControlResult::Unit),
                    _ => Err(RuntimeError::Unavailable(
                        "unsupported relay control operation".to_owned(),
                    )),
                });
            let _ = outcomes.try_send(RelayControlOutcome {
                request_id: pending.request_id,
                respond: pending.respond,
                command_id: pending.command_id,
                command_descriptor: pending.command_descriptor,
                operation: pending.operation,
                result: result.map_err(|error| EngineError::Transport(error.to_string())),
            });
        });
    }

    pub(super) async fn finish_relay_control(
        &mut self,
        outcome: RelayControlOutcome,
        events: &mpsc::Sender<EngineEvent>,
    ) {
        self.relay_control_in_flight = false;
        let idempotency = outcome
            .command_id
            .as_ref()
            .map(|command_id| IdempotencyCommitContext {
                command_id: command_id.clone(),
                command_descriptor: outcome.command_descriptor.clone(),
            });
        let commit = match (outcome.operation, outcome.result) {
            (
                RelayControlOperation::Command(EngineCommand::SetNickname { nickname }),
                Ok(RelayControlResult::Unit),
            ) => {
                let prepared = self
                    .with_runtime(|runtime| runtime.prepare_nickname(nickname.clone()))
                    .and_then(|_| {
                        self.with_runtime_idempotent(
                            idempotency.as_ref(),
                            |runtime| runtime.commit_nickname(nickname),
                            |profile| json_response(profile),
                        )
                    });
                prepared
                    .and_then(|(value, runtime_events)| Ok((json_response(value)?, runtime_events)))
            }
            (
                RelayControlOperation::Command(EngineCommand::RefreshPairingCode),
                Ok(RelayControlResult::PairingCode(code)),
            ) => {
                let prepared = self
                    .with_runtime(|runtime| runtime.prepare_refresh_pairing_code())
                    .and_then(|_| {
                        self.with_runtime_idempotent(
                            idempotency.as_ref(),
                            |runtime| {
                                runtime.commit_pairing_code(code.clone())?;
                                Ok(code.clone())
                            },
                            |value| json_response(value),
                        )
                    });
                prepared
                    .and_then(|(value, runtime_events)| Ok((json_response(value)?, runtime_events)))
            }
            (
                RelayControlOperation::Command(EngineCommand::SubmitPairingCode { code }),
                Ok(RelayControlResult::PairingItem(item)),
            ) => {
                let prepared = self
                    .with_runtime(|runtime| runtime.prepare_submit_pairing_code(code))
                    .and_then(|_| {
                        self.with_runtime_idempotent(
                            idempotency.as_ref(),
                            |runtime| runtime.commit_submitted_pairing(*item.clone()),
                            |value| json_response(value),
                        )
                    });
                prepared
                    .and_then(|(value, runtime_events)| Ok((json_response(value)?, runtime_events)))
            }
            (
                RelayControlOperation::Command(EngineCommand::PairingInbox),
                Ok(RelayControlResult::PairingInbox(remote)),
            ) => {
                let result = self
                    .with_runtime(|runtime| runtime.merge_pairing_inbox(remote))
                    .and_then(|(result, runtime_events)| {
                        for acknowledgement in &result.acknowledgements {
                            self.enqueue_pairing_acknowledgement(&acknowledgement.pairing_id);
                        }
                        Ok((json_response(result)?, runtime_events))
                    });
                if result.is_ok() {
                    self.pairing_inbox_retry_at = None;
                    self.pairing_inbox_retry_attempt = 0;
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "info".to_owned(),
                                message: "pairing inbox synchronization completed".to_owned(),
                            },
                        })
                        .await;
                } else if let Err(error) = &result {
                    let retry_in_ms = self.schedule_pairing_inbox_retry();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "pairing inbox merge failed retry_in_ms={retry_in_ms}: {error}"
                                ),
                            },
                        })
                        .await;
                }
                result
            }
            (
                RelayControlOperation::Command(EngineCommand::CancelPairing { pairing_id }),
                Ok(RelayControlResult::Unit),
            ) => self
                .with_runtime(|runtime| runtime.prepare_cancel_pairing(&pairing_id))
                .and_then(|(_, mut runtime_events)| {
                    let (_, confirm_events) = self.with_runtime_idempotent(
                        idempotency.as_ref(),
                        |runtime| runtime.confirm_pairing_cancelled(&pairing_id),
                        |_| Ok(ResponsePayload::Empty),
                    )?;
                    runtime_events.extend(confirm_events);
                    Ok((ResponsePayload::Empty, runtime_events))
                }),
            (
                RelayControlOperation::AcknowledgePairing { pairing_id },
                Ok(RelayControlResult::Unit),
            ) => self
                .database
                .complete_pending_pairing_acknowledgement(&pairing_id)
                .map(|()| (ResponsePayload::Empty, Vec::new())),
            (
                RelayControlOperation::ConfirmContact { pairing_id, .. },
                Ok(RelayControlResult::Unit),
            ) => self
                .database
                .complete_pending_contact_confirmation(&pairing_id)
                .map(|()| (ResponsePayload::Empty, Vec::new())),
            (RelayControlOperation::AcknowledgePairing { pairing_id }, Err(error)) => {
                let _ = self
                    .database
                    .put_pending_pairing_acknowledgement(&pairing_id, Some(&error.to_string()));
                Err(error)
            }
            (RelayControlOperation::ConfirmContact { pairing_id, .. }, Err(error)) => {
                let _ = self
                    .database
                    .record_pending_contact_confirmation_error(&pairing_id, &error.to_string());
                Err(error)
            }
            (RelayControlOperation::Command(EngineCommand::PairingInbox), Err(error)) => {
                let retry_in_ms = self.schedule_pairing_inbox_retry();
                let _ = events
                    .send(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "pairing inbox synchronization failed retry_in_ms={retry_in_ms}: {error}"
                            ),
                        },
                    })
                    .await;
                Err(error)
            }
            (_, Ok(_)) => Err(EngineError::InvalidCommand(
                "relay control result did not match command".to_owned(),
            )),
            (_, Err(error)) => Err(error),
        };
        match commit {
            Ok((payload, runtime_events)) => {
                for event in runtime_events {
                    let _ = events.send(EngineEvent::Runtime { event }).await;
                }
                if outcome.respond {
                    let _ = events
                        .send(EngineEvent::Response {
                            request_id: outcome.request_id,
                            result: ResponseResult::Ok { payload },
                        })
                        .await;
                }
            }
            Err(error) => {
                let error_text = error.to_string().to_ascii_lowercase();
                if error_text.contains("http 401") || error_text.contains("unauthorized") {
                    // A stale bearer token cannot recover through ordinary
                    // backoff. Force a fresh challenge/register session.
                    self.relay.invalidate_session();
                    self.advance_connection_generation();
                    self.schedule_relay_bootstrap_now();
                }
                if outcome.respond {
                    let _ = events
                        .send(EngineEvent::Response {
                            request_id: outcome.request_id,
                            result: ResponseResult::Error {
                                code: error_code(&error).to_owned(),
                                message: error.to_string(),
                            },
                        })
                        .await;
                }
            }
        }
        if let Some(sender) = self.relay_control_sender.clone() {
            self.start_next_relay_control(sender);
        }
    }

    pub(super) fn connection_snapshot(&mut self, detail: &str) -> ConnectionSnapshot {
        let now = Instant::now();
        let status = match &self.connection_state {
            ConnectionState::Connected => ProbeStatus::Online,
            ConnectionState::Connecting
            | ConnectionState::Authenticating
            | ConnectionState::WaitingForReady => ProbeStatus::Checking,
            ConnectionState::Backoff { .. }
            | ConnectionState::Disconnected
            | ConnectionState::WaitingForTor
            | ConnectionState::Stopped => ProbeStatus::Offline,
        };
        for key in [ProbeKey::engine(), ProbeKey::relay()] {
            self.probe_coordinator.ensure(key.clone(), now);
            self.probe_coordinator
                .record_result(&key, now, status, None, Duration::from_secs(10));
        }
        let onion_key = ProbeKey::onion_service();
        self.probe_coordinator.ensure(onion_key.clone(), now);
        self.probe_coordinator.record_result(
            &onion_key,
            now,
            if self.local_peer_endpoint.is_some() {
                ProbeStatus::Online
            } else {
                ProbeStatus::Offline
            },
            None,
            Duration::from_secs(30),
        );
        ConnectionSnapshot {
            state: self.connection_state.clone(),
            generation: self.connection_generation,
            detail: detail.to_owned(),
        }
    }

    pub(super) fn advance_connection_generation(&mut self) {
        self.connection_generation = self.connection_generation.wrapping_add(1);
    }

    pub(super) fn schedule_relay_retry(&mut self) {
        self.relay_retry_attempt = self.relay_retry_attempt.saturating_add(1);
        let seconds = match self.relay_retry_attempt {
            0 | 1 => 3,
            2 => 5,
            3 => 8,
            4 => 12,
            _ => 15,
        };
        self.relay_retry_at = Some(Instant::now() + Duration::from_secs(seconds));
        self.connection_state = ConnectionState::Backoff {
            attempt: self.relay_retry_attempt,
            retry_in_ms: seconds.saturating_mul(1_000),
        };
    }

    pub(super) fn schedule_relay_bootstrap_now(&mut self) {
        self.relay_retry_at = Some(Instant::now());
        self.connection_state = ConnectionState::Connecting;
    }

    pub(super) fn start_relay_bootstrap(&mut self, outcomes: mpsc::Sender<RelayBootstrapOutcome>) {
        self.relay_retry_at = None;
        if self.socks5_url.is_none() || !self.network_online {
            self.schedule_relay_retry();
            return;
        }
        self.relay_bootstrap_in_flight = true;
        let relay_onion_url = self.relay_onion_url.clone();
        let socks5_url = self.socks5_url.clone();
        let generation = self.connection_generation;
        // `Identity` is intentionally non-Clone. The relay bootstrap worker
        // needs an isolated signing handle, so rehydrate one from the actor's
        // private bytes and keep it confined to the worker closure.
        let identity = Identity::from_private_key_bytes(self.identity.private_key_bytes());
        tokio::task::spawn_blocking(move || {
            let mut relay = SharedRelayActor::new(relay_onion_url, socks5_url, identity);
            let outcome = match relay.ensure_session() {
                Ok(()) => RelayBootstrapOutcome::Ready {
                    generation,
                    relay: Box::new(relay),
                },
                Err(error) => RelayBootstrapOutcome::Failed { generation, error },
            };
            let _ = outcomes.try_send(outcome);
        });
    }

    pub(super) async fn finish_relay_bootstrap(
        &mut self,
        outcome: RelayBootstrapOutcome,
        events: &mpsc::Sender<EngineEvent>,
    ) {
        self.relay_bootstrap_in_flight = false;
        let generation = match &outcome {
            RelayBootstrapOutcome::Ready { generation, .. }
            | RelayBootstrapOutcome::Failed { generation, .. } => *generation,
        };
        if generation != self.connection_generation {
            self.schedule_relay_bootstrap_now();
            return;
        }
        match outcome {
            RelayBootstrapOutcome::Ready { relay, .. } => {
                self.relay.shutdown();
                self.relay = relay;
                self.relay_retry_attempt = 0;
                self.connection_state = ConnectionState::Connecting;
                let _ = events
                    .send(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "info".to_owned(),
                            message: "relay bootstrap recovered".to_owned(),
                        },
                    })
                    .await;
                // The profile is already committed by the public nickname
                // command. Do not repeat its HTTP mutation on the actor after
                // every reconnect; that would reintroduce a blocking relay
                // effect into the event loop. A subsequent explicit nickname
                // change is handled by the relay-control worker.
                // Pairing inbox HTTP is also a relay effect. Queue it behind
                // the worker so reconnect completion never blocks the actor.
                self.enqueue_pairing_inbox_refresh();
                if let Err(error) = self.flush_pending_send_effects() {
                    self.schedule_relay_retry();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "relay bootstrap recovered but send flush failed: {error}"
                                ),
                            },
                        })
                        .await;
                    return;
                }
                if let Err(error) = self.flush_pending_receipt_effects() {
                    self.receipt_queue_failed_after_commit =
                        self.receipt_queue_failed_after_commit.saturating_add(1);
                    self.schedule_relay_retry();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "receipt_queue_failed_after_commit: relay recovery flush deferred ({error_kind})",
                                    error_kind = super::error_kind(&error),
                                ),
                            },
                        })
                        .await;
                    return;
                }
                let _ = events
                    .send(EngineEvent::Connection {
                        snapshot: self.connection_snapshot("relay bootstrap recovered"),
                    })
                    .await;
            }
            RelayBootstrapOutcome::Failed { error, .. } => {
                if is_permanent_relay_bootstrap_error(&error) {
                    self.relay_retry_at = None;
                    self.connection_state = ConnectionState::Stopped;
                    let message = format!(
                        "relay bootstrap has a permanent configuration or protocol error: {error}"
                    );
                    let _ = events
                        .send(EngineEvent::Runtime {
                            event: torchat_client_runtime::RuntimeEvent::RuntimeError {
                                message: message.clone(),
                            },
                        })
                        .await;
                    let _ = events
                        .send(EngineEvent::Connection {
                            snapshot: self.connection_snapshot(&message),
                        })
                        .await;
                    return;
                }
                self.schedule_relay_retry();
                let retry_in_ms = match self.connection_state {
                    ConnectionState::Backoff { retry_in_ms, .. } => Some(retry_in_ms),
                    _ => None,
                };
                let _ = events
                    .send(EngineEvent::Runtime {
                        event: transport_status_event(
                            torchat_client_runtime::TransportComponent::Relay,
                            torchat_client_runtime::TransportProbeState::Degraded,
                            format!("relay circuit warming; retrying: {error}"),
                            self.tor_status.progress,
                            None,
                            self.relay_retry_attempt,
                            retry_in_ms,
                            self.connection_generation,
                            None,
                            self.clock.now_ms(),
                        ),
                    })
                    .await;
                let _ = events
                    .send(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "relay bootstrap retry {} failed: {error}",
                                self.relay_retry_attempt
                            ),
                        },
                    })
                    .await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::push_bounded;
    use std::collections::VecDeque;

    #[test]
    fn bounded_relay_control_queue_rejects_flood_and_preserves_fifo() {
        let mut queue = VecDeque::new();
        for item in 0..64 {
            assert!(push_bounded(&mut queue, item, 64));
        }
        assert!(!push_bounded(&mut queue, 64, 64));
        assert_eq!(queue.len(), 64);
        assert_eq!(
            queue.into_iter().collect::<Vec<_>>(),
            (0..64).collect::<Vec<_>>()
        );
    }
}
