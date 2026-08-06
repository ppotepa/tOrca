use super::*;

use crate::{
    input::{CommandRequestContext, EngineInputEnvelope, EngineTimerKind},
    processing::EngineProcessingResult,
    scheduler::EngineSchedulerPlan,
};

impl ClientEngineActor {
    pub(crate) fn process_peer_input(
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

    pub(crate) fn process_relay_input(&mut self, event: RelayEvent) -> EngineProcessingResult {
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

    pub(crate) fn process_platform_input(
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
                        result: ResponseResult::error(error_code(&error), error.to_string()),
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

    pub(crate) fn process_timer_input(
        &mut self,
        causation_id: uuid::Uuid,
        kind: EngineTimerKind,
    ) -> EngineResult<EngineProcessingResult> {
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match kind {
            EngineTimerKind::RelayPoll => {
                while let Some(event) = self.relay.poll_event() {
                    result
                        .derived_inputs
                        .push(EngineInputEnvelope::relay_event_caused(
                            unix_ms(),
                            causation_id,
                            event,
                        ));
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
                let resumed = self.resume_due_durable_operation(causation_id)?;
                result.events.extend(resumed.events);
                result.effects.extend(resumed.effects);
                result.derived_inputs.extend(resumed.derived_inputs);
                result.changes.merge(resumed.changes);
                result.scheduler_plan_changed |= resumed.scheduler_plan_changed;
            }
        }
        Ok(result)
    }

    pub(crate) fn process_shutdown_input(&mut self) -> EngineProcessingResult {
        self.advance_connection_generation();
        self.relay.shutdown();
        self.connection_state = ConnectionState::Stopped;
        EngineProcessingResult::stop(vec![EngineEvent::Connection {
            snapshot: self.connection_snapshot("engine shutdown"),
        }])
    }

    pub(crate) fn scheduler_plan(&self, generation: u64) -> EngineResult<EngineSchedulerPlan> {
        let retry_deadline = self.next_retry_deadline()?;
        let ordinary_retry_at = self.next_retry_wakeup_at(retry_deadline)?;
        let durable_retry_at = self.next_durable_operation_wakeup_at()?;
        Ok(EngineSchedulerPlan {
            generation,
            relay_poll_at: Some(self.relay_poll_at),
            peer_probe_at: Some(self.probe_coordinator.next_round_at()),
            retry_at: [ordinary_retry_at, durable_retry_at]
                .into_iter()
                .flatten()
                .min(),
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
