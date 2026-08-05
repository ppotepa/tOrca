use super::*;

use tokio::sync::watch;

use crate::{
    input::{
        CommandRequestContext, EngineInput, EngineInputEnvelope, EngineTimerKind,
    },
    processing::{EngineProcessingResult, ProcessingControl},
    scheduler::{EngineSchedulerPlan, spawn_engine_scheduler},
};

impl ClientEngineActor {
    pub async fn run_unified(
        mut self,
        mut inbox: mpsc::Receiver<EngineInputEnvelope>,
        inbox_tx: mpsc::Sender<EngineInputEnvelope>,
        events: mpsc::Sender<EngineEvent>,
        shutdown: CancellationToken,
    ) -> EngineResult<()> {
        let (peer_transport, peer_events) =
            PeerTransportHandle::bind(self.identity.private_key_bytes())
                .await
                .map_err(|error| EngineError::Transport(error.to_string()))?;
        if let Some(endpoint) = self.local_peer_endpoint.clone() {
            peer_transport.set_local_endpoint(endpoint);
        }
        for contact in self.list_contacts()? {
            self.probe_coordinator.ensure(
                ProbeKey::contact(contact.installation_id.clone()),
                Instant::now(),
            );
            if let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            {
                self.database
                    .ensure_contact_endpoint_capability(&contact.installation_id)?;
                if let Some(base_endpoint) = self.local_peer_endpoint.clone() {
                    let (capability_id, secret) =
                        self.local_capability_credentials(&contact.installation_id)?;
                    let local_endpoint =
                        self.local_endpoint_for_contact(&contact.installation_id, &base_endpoint)?;
                    peer_transport.authorize_contact(
                        &endpoint,
                        local_endpoint,
                        capability_id,
                        secret,
                    );
                }
            }
        }

        let local_port = peer_transport.local_port();
        self.peer_transport = Some(peer_transport);
        spawn_peer_ingress(
            peer_events,
            inbox_tx.clone(),
            shutdown.clone(),
        );
        spawn_shutdown_ingress(
            shutdown.clone(),
            inbox_tx.clone(),
        );

        let mut startup_events = Vec::new();
        for contact in self.list_contacts()? {
            startup_events.extend(
                self.drain_pending_pre_welcome(&contact.installation_id)?
                    .into_iter()
                    .map(|event| EngineEvent::Runtime { event }),
            );
        }
        startup_events.extend(
            self.recover_pending_inbound_peer_envelopes()?
                .into_iter()
                .map(|event| EngineEvent::Runtime { event }),
        );
        startup_events.push(EngineEvent::PlatformAction {
            action: PlatformAction::ConfigureOnionService {
                local_port,
                virtual_port: PEER_VIRTUAL_PORT,
                generation: self.expected_onion_generation,
            },
        });
        startup_events.push(EngineEvent::Connection {
            snapshot: self.connection_snapshot("engine actor initialized"),
        });
        startup_events.push(EngineEvent::Log {
            log: EngineLogEvent {
                level: "info".to_owned(),
                message: format!("peer listener bound on local port {local_port}"),
            },
        });
        startup_events.push(EngineEvent::Log {
            log: EngineLogEvent {
                level: "info".to_owned(),
                message: format!("client engine actor started for {:?}", self.platform),
            },
        });
        publish_events(&events, startup_events).await;

        let mut scheduler_generation = 1_u64;
        let initial_plan = self.scheduler_plan(scheduler_generation)?;
        let (scheduler_tx, scheduler_rx) = watch::channel(initial_plan);
        spawn_engine_scheduler(scheduler_rx, inbox_tx, shutdown.clone());

        while let Some(envelope) = inbox.recv().await {
            let result = self.process_unified_input(envelope, scheduler_generation)?;
            let plan_changed = result.scheduler_plan_changed;
            let should_stop = result.should_stop();
            publish_events(&events, result.events).await;

            if should_stop {
                shutdown.cancel();
                break;
            }

            if plan_changed {
                scheduler_generation = scheduler_generation.saturating_add(1);
                scheduler_tx.send_replace(self.scheduler_plan(scheduler_generation)?);
            }
        }

        shutdown.cancel();
        self.relay.shutdown();
        Ok(())
    }

    fn process_unified_input(
        &mut self,
        envelope: EngineInputEnvelope,
        scheduler_generation: u64,
    ) -> EngineResult<EngineProcessingResult> {
        match envelope.input {
            EngineInput::Command(command) => Ok(self.process_command_input(command)),
            EngineInput::PeerEvent(event) => Ok(self.process_peer_input(event)),
            EngineInput::RelayEvent(event) => Ok(self.process_relay_input(event)),
            EngineInput::PlatformFact { request, fact } => {
                Ok(self.process_platform_input(request, fact))
            }
            EngineInput::TimerElapsed { kind, generation } => {
                if generation != scheduler_generation {
                    return Ok(EngineProcessingResult::empty());
                }
                self.process_timer_input(kind)
            }
            EngineInput::EffectOutcome => Ok(EngineProcessingResult::empty()),
            EngineInput::ShutdownRequested => Ok(self.process_shutdown_input()),
        }
    }

    fn process_command_input(
        &mut self,
        envelope: EngineCommandEnvelope,
    ) -> EngineProcessingResult {
        let should_stop = matches!(&envelope.command, EngineCommand::Shutdown);
        let command_id = envelope.command_id.clone();
        let command_type = serde_json::to_value(&envelope.command)
            .ok()
            .and_then(|value| {
                value
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| "unknown".to_owned());
        let command_descriptor = idempotency_descriptor(&envelope.command, &command_type);
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;

        if let Some(command_id) = command_id.as_deref()
            && let Ok(Some((stored_type, result_json, _revision))) =
                self.database.load_processed_command(command_id)
        {
            let stored_result = if stored_type != command_descriptor {
                ResponseResult::Error {
                    code: "idempotency_conflict".to_owned(),
                    message: "command id was already used for a different command".to_owned(),
                }
            } else {
                match serde_json::from_str::<ResponsePayload>(&result_json) {
                    Ok(payload) => ResponseResult::Ok { payload },
                    Err(_) => ResponseResult::Error {
                        code: "idempotency_corrupt".to_owned(),
                        message: "stored command result is invalid".to_owned(),
                    },
                }
            };
            result.events.push(EngineEvent::Response {
                request_id: envelope.request_id,
                result: stored_result,
            });
            if should_stop {
                result.control = ProcessingControl::Stop;
            }
            return result;
        }

        let idempotency = command_id.as_ref().map(|command_id| IdempotencyCommitContext {
            command_id: command_id.clone(),
            command_descriptor: command_descriptor.clone(),
        });
        match self.handle_command(envelope.command, idempotency.as_ref()) {
            Ok((payload, runtime_events, connection_snapshot)) => {
                if let Some(snapshot) = connection_snapshot {
                    result.events.push(EngineEvent::Connection { snapshot });
                }
                result.events.extend(
                    runtime_events
                        .into_iter()
                        .map(|event| EngineEvent::Runtime { event }),
                );
                result.events.append(&mut self.pending_engine_events);
                if let Some(command_id) = command_id.as_deref()
                    && let Ok((_, revision)) = self.projection_head()
                    && let Ok(result_json) = serde_json::to_string(&payload)
                {
                    let _ = self.database.save_processed_command(
                        command_id,
                        &command_descriptor,
                        &result_json,
                        revision,
                    );
                }
                result.events.push(EngineEvent::Response {
                    request_id: envelope.request_id,
                    result: ResponseResult::Ok { payload },
                });
            }
            Err(error) => {
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Response {
                    request_id: envelope.request_id,
                    result: ResponseResult::Error {
                        code: error_code(&error).to_owned(),
                        message: error.to_string(),
                    },
                });
            }
        }
        if should_stop {
            result.control = ProcessingControl::Stop;
        }
        result
    }

    fn process_peer_input(
        &mut self,
        event: PeerTransportEvent,
    ) -> EngineProcessingResult {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match self.handle_peer_event(event) {
            Ok(runtime_events) => {
                result.events.extend(
                    runtime_events
                        .into_iter()
                        .map(|event| EngineEvent::Runtime { event }),
                );
                result.events.append(&mut self.pending_engine_events);
            }
            Err(error) => {
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "error".to_owned(),
                        message: format!("peer event handling failed: {error}"),
                    },
                });
            }
        }
        result
    }

    fn process_relay_input(&mut self, event: RelayEvent) -> EngineProcessingResult {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match self.handle_relay_event(event) {
            Ok((runtime_events, connection_snapshot, log_event)) => {
                if let Some(snapshot) = connection_snapshot {
                    result.events.push(EngineEvent::Connection { snapshot });
                }
                if let Some(log) = log_event {
                    result.events.push(EngineEvent::Log { log });
                }
                result.events.extend(
                    runtime_events
                        .into_iter()
                        .map(|event| EngineEvent::Runtime { event }),
                );
                result.events.append(&mut self.pending_engine_events);
            }
            Err(error) => {
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "error".to_owned(),
                        message: format!("relay event handling failed: {error}"),
                    },
                });
            }
        }
        result
    }

    fn process_platform_input(
        &mut self,
        request: Option<CommandRequestContext>,
        fact: PlatformFact,
    ) -> EngineProcessingResult {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match self.apply_platform_fact(fact) {
            Ok(runtime_events) => {
                result.events.push(EngineEvent::Connection {
                    snapshot: self.connection_snapshot("platform fact applied"),
                });
                result.events.extend(
                    runtime_events
                        .into_iter()
                        .map(|event| EngineEvent::Runtime { event }),
                );
                result.events.append(&mut self.pending_engine_events);
                if let Some(request) = request {
                    result.events.push(EngineEvent::Response {
                        request_id: request.request_id,
                        result: ResponseResult::Ok {
                            payload: ResponsePayload::Empty,
                        },
                    });
                }
            }
            Err(error) => {
                self.pending_engine_events.clear();
                if let Some(request) = request {
                    result.events.push(EngineEvent::Response {
                        request_id: request.request_id,
                        result: ResponseResult::Error {
                            code: error_code(&error).to_owned(),
                            message: error.to_string(),
                        },
                    });
                } else {
                    result.events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "error".to_owned(),
                            message: format!("platform fact handling failed: {error}"),
                        },
                    });
                }
            }
        }
        result
    }

    fn process_timer_input(
        &mut self,
        kind: EngineTimerKind,
    ) -> EngineResult<EngineProcessingResult> {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match kind {
            EngineTimerKind::RelayPoll => {
                while let Some(event) = self.relay.poll_event() {
                    let relay_result = self.process_relay_input(event);
                    result.events.extend(relay_result.events);
                }
                self.relay_poll_at = Instant::now() + self.relay_poll_interval();
            }
            EngineTimerKind::PeerProbeRound => {
                if let Ok((_, runtime_events)) =
                    self.with_runtime(|runtime| runtime.expire_pending_pairings())
                {
                    result.events.extend(
                        runtime_events
                            .into_iter()
                            .map(|event| EngineEvent::Runtime { event }),
                    );
                }
                let _ = self.retry_capability_deliveries();
                let _ = self.queue_endpoint_update_probes();
                let _ = self.queue_presence_heartbeats();
                let now = Instant::now();
                self.probe_coordinator
                    .schedule_round(now, self.peer_probe_interval());
                result.events.append(&mut self.pending_engine_events);
            }
            EngineTimerKind::RetryDue => {
                if let Some(deadline) = self.next_retry_deadline()? {
                    result
                        .events
                        .extend(self.run_retry_scheduler_collect(deadline));
                    result.events.append(&mut self.pending_engine_events);
                }
            }
        }
        Ok(result)
    }

    fn process_shutdown_input(&mut self) -> EngineProcessingResult {
        self.advance_connection_generation();
        self.relay.shutdown();
        self.connection_state = ConnectionState::Stopped;
        EngineProcessingResult::stop(vec![EngineEvent::Connection {
            snapshot: self.connection_snapshot("engine shutdown"),
        }])
    }

    fn scheduler_plan(&self, generation: u64) -> EngineResult<EngineSchedulerPlan> {
        let retry_deadline = self.next_retry_deadline()?;
        Ok(EngineSchedulerPlan {
            generation,
            relay_poll_at: Some(self.relay_poll_at),
            peer_probe_at: Some(self.probe_coordinator.next_round_at()),
            retry_at: self.next_retry_wakeup_at(retry_deadline)?,
        })
    }

    fn relay_poll_interval(&self) -> Duration {
        if !self.network_online {
            Duration::from_secs(30)
        } else if self.battery_saver || self.device_idle || self.background_restricted {
            Duration::from_secs(5)
        } else {
            RELAY_POLL_INTERVAL
        }
    }

    fn peer_probe_interval(&self) -> Duration {
        if !self.network_online {
            Duration::from_secs(300)
        } else if self.battery_saver || self.device_idle || self.background_restricted {
            Duration::from_secs(180)
        } else if self.app_foreground {
            Duration::from_secs(30)
        } else {
            Duration::from_secs(120)
        }
    }
}

fn spawn_peer_ingress(
    mut peer_events: mpsc::Receiver<PeerTransportEvent>,
    inbox: mpsc::Sender<EngineInputEnvelope>,
    shutdown: CancellationToken,
) {
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = shutdown.cancelled() => break,
                event = peer_events.recv() => {
                    let Some(event) = event else {
                        break;
                    };
                    if inbox
                        .send(EngineInputEnvelope::peer_event(unix_ms(), event))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
    });
}

fn spawn_shutdown_ingress(
    shutdown: CancellationToken,
    inbox: mpsc::Sender<EngineInputEnvelope>,
) {
    tokio::spawn(async move {
        shutdown.cancelled().await;
        let _ = inbox
            .send(EngineInputEnvelope::shutdown(unix_ms()))
            .await;
    });
}

async fn publish_events(
    events: &mpsc::Sender<EngineEvent>,
    outputs: impl IntoIterator<Item = EngineEvent>,
) {
    for event in outputs {
        if events.send(event).await.is_err() {
            break;
        }
    }
}
