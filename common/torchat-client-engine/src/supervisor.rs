use std::collections::BTreeMap;

pub const COMMAND_CHANNEL_CAPACITY: usize = 64;
pub const WORKER_OUTCOME_CHANNEL_CAPACITY: usize = 256;
pub const DELIVERY_CHANNEL_CAPACITY: usize = 256;
pub const PROJECTION_CHANNEL_CAPACITY: usize = 256;
pub const NOTIFICATION_CHANNEL_CAPACITY: usize = 64;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum WorkerKind {
    State,
    Relay,
    Peer,
    Delivery,
    RetryTimer,
    Projection,
    Notification,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkerStatus {
    Stopped,
    Starting,
    Running,
    Restarting { attempt: u32, retry_at_ms: i64 },
    Failed { reason: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkerFailureClass {
    Fatal,
    Restartable,
    Rebuildable,
    BestEffort,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SupervisorAction {
    StartWorker { worker: WorkerKind },
    RestartWorker {
        worker: WorkerKind,
        attempt: u32,
        retry_at_ms: i64,
    },
    RebuildWorker { worker: WorkerKind },
    MarkDegraded { worker: WorkerKind, reason: String },
    EmitFatal { worker: WorkerKind, reason: String },
    StopWorker { worker: WorkerKind },
    CompleteShutdown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShutdownPhase {
    Running,
    StopAcceptingCommands,
    StopEphemeral,
    DrainDelivery,
    StopTransports,
    DrainProjections,
    StopState,
    Complete,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineSupervisor {
    workers: BTreeMap<WorkerKind, WorkerStatus>,
    pub generation: u64,
    pub shutdown_phase: ShutdownPhase,
}

impl Default for EngineSupervisor {
    fn default() -> Self {
        let workers = [
            WorkerKind::State,
            WorkerKind::Relay,
            WorkerKind::Peer,
            WorkerKind::Delivery,
            WorkerKind::RetryTimer,
            WorkerKind::Projection,
            WorkerKind::Notification,
        ]
        .into_iter()
        .map(|worker| (worker, WorkerStatus::Stopped))
        .collect();
        Self {
            workers,
            generation: 0,
            shutdown_phase: ShutdownPhase::Running,
        }
    }
}

impl EngineSupervisor {
    pub fn status(&self, worker: WorkerKind) -> &WorkerStatus {
        self.workers
            .get(&worker)
            .expect("all engine workers are registered")
    }

    pub fn start_all(&mut self) -> Vec<SupervisorAction> {
        self.generation = self.generation.saturating_add(1);
        self.workers
            .iter_mut()
            .map(|(worker, status)| {
                *status = WorkerStatus::Starting;
                SupervisorAction::StartWorker { worker: *worker }
            })
            .collect()
    }

    pub fn worker_started(&mut self, worker: WorkerKind) {
        self.workers.insert(worker, WorkerStatus::Running);
    }

    pub fn worker_failed(
        &mut self,
        worker: WorkerKind,
        reason: impl Into<String>,
        now_ms: i64,
    ) -> Vec<SupervisorAction> {
        let reason = reason.into();
        let class = failure_class(worker);
        match class {
            WorkerFailureClass::Fatal => {
                self.workers.insert(
                    worker,
                    WorkerStatus::Failed {
                        reason: reason.clone(),
                    },
                );
                vec![SupervisorAction::EmitFatal { worker, reason }]
            }
            WorkerFailureClass::Restartable => {
                let attempt = match self.workers.get(&worker) {
                    Some(WorkerStatus::Restarting { attempt, .. }) => attempt.saturating_add(1),
                    _ => 1,
                };
                let retry_at_ms = now_ms.saturating_add(restart_delay_ms(attempt));
                self.workers.insert(
                    worker,
                    WorkerStatus::Restarting {
                        attempt,
                        retry_at_ms,
                    },
                );
                vec![
                    SupervisorAction::MarkDegraded {
                        worker,
                        reason,
                    },
                    SupervisorAction::RestartWorker {
                        worker,
                        attempt,
                        retry_at_ms,
                    },
                ]
            }
            WorkerFailureClass::Rebuildable => {
                self.workers.insert(worker, WorkerStatus::Starting);
                vec![SupervisorAction::RebuildWorker { worker }]
            }
            WorkerFailureClass::BestEffort => {
                self.workers.insert(
                    worker,
                    WorkerStatus::Failed {
                        reason: reason.clone(),
                    },
                );
                vec![SupervisorAction::MarkDegraded { worker, reason }]
            }
        }
    }

    pub fn begin_shutdown(&mut self) -> Vec<SupervisorAction> {
        if self.shutdown_phase != ShutdownPhase::Running {
            return Vec::new();
        }
        self.shutdown_phase = ShutdownPhase::StopAcceptingCommands;
        Vec::new()
    }

    pub fn advance_shutdown(&mut self) -> Vec<SupervisorAction> {
        use ShutdownPhase as Phase;
        use WorkerKind as Worker;

        let (next, actions) = match self.shutdown_phase {
            Phase::Running => return self.begin_shutdown(),
            Phase::StopAcceptingCommands => (
                Phase::StopEphemeral,
                vec![SupervisorAction::StopWorker {
                    worker: Worker::Notification,
                }],
            ),
            Phase::StopEphemeral => (
                Phase::DrainDelivery,
                vec![SupervisorAction::StopWorker {
                    worker: Worker::RetryTimer,
                }],
            ),
            Phase::DrainDelivery => (
                Phase::StopTransports,
                vec![SupervisorAction::StopWorker {
                    worker: Worker::Delivery,
                }],
            ),
            Phase::StopTransports => (
                Phase::DrainProjections,
                vec![
                    SupervisorAction::StopWorker {
                        worker: Worker::Peer,
                    },
                    SupervisorAction::StopWorker {
                        worker: Worker::Relay,
                    },
                ],
            ),
            Phase::DrainProjections => (
                Phase::StopState,
                vec![SupervisorAction::StopWorker {
                    worker: Worker::Projection,
                }],
            ),
            Phase::StopState => (
                Phase::Complete,
                vec![
                    SupervisorAction::StopWorker {
                        worker: Worker::State,
                    },
                    SupervisorAction::CompleteShutdown,
                ],
            ),
            Phase::Complete => return Vec::new(),
        };
        self.shutdown_phase = next;
        actions
    }
}

pub const fn failure_class(worker: WorkerKind) -> WorkerFailureClass {
    match worker {
        WorkerKind::State => WorkerFailureClass::Fatal,
        WorkerKind::Relay | WorkerKind::Peer | WorkerKind::Delivery | WorkerKind::RetryTimer => {
            WorkerFailureClass::Restartable
        }
        WorkerKind::Projection => WorkerFailureClass::Rebuildable,
        WorkerKind::Notification => WorkerFailureClass::BestEffort,
    }
}

fn restart_delay_ms(attempt: u32) -> i64 {
    let exponent = attempt.saturating_sub(1).min(8);
    (1_000_i64 << exponent).min(60_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storage_state_failure_is_fatal_but_relay_is_restartable() {
        let mut supervisor = EngineSupervisor::default();
        let fatal = supervisor.worker_failed(WorkerKind::State, "sqlite failed", 0);
        assert!(matches!(fatal.as_slice(), [SupervisorAction::EmitFatal { .. }]));

        let relay = supervisor.worker_failed(WorkerKind::Relay, "socket closed", 10);
        assert!(matches!(
            relay.as_slice(),
            [
                SupervisorAction::MarkDegraded { .. },
                SupervisorAction::RestartWorker {
                    attempt: 1,
                    retry_at_ms: 1_010,
                    ..
                }
            ]
        ));
    }

    #[test]
    fn shutdown_orders_delivery_before_transports_and_state() {
        let mut supervisor = EngineSupervisor::default();
        supervisor.begin_shutdown();
        assert_eq!(supervisor.shutdown_phase, ShutdownPhase::StopAcceptingCommands);
        supervisor.advance_shutdown();
        supervisor.advance_shutdown();
        assert_eq!(supervisor.shutdown_phase, ShutdownPhase::DrainDelivery);
        let delivery = supervisor.advance_shutdown();
        assert_eq!(
            delivery,
            vec![SupervisorAction::StopWorker {
                worker: WorkerKind::Delivery,
            }]
        );
        while supervisor.shutdown_phase != ShutdownPhase::Complete {
            supervisor.advance_shutdown();
        }
        assert_eq!(supervisor.shutdown_phase, ShutdownPhase::Complete);
    }

    #[test]
    fn channel_capacities_are_bounded() {
        assert!(COMMAND_CHANNEL_CAPACITY > 0);
        assert!(WORKER_OUTCOME_CHANNEL_CAPACITY >= COMMAND_CHANNEL_CAPACITY);
        assert!(DELIVERY_CHANNEL_CAPACITY > 0);
        assert!(PROJECTION_CHANNEL_CAPACITY > 0);
        assert!(NOTIFICATION_CHANNEL_CAPACITY > 0);
    }
}
