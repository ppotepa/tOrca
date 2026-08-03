use tokio::sync::mpsc;
use tokio::time::Duration;
use tokio_util::sync::CancellationToken;

use crate::{
    ClientEngineActor, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError,
    EngineEvent, EngineFatalError, EngineResult, PlatformFact, anti_rollback::MlsEpochAnchor,
    event::EngineEventReceiver, logging::StartupJournal,
};

pub const COMMAND_CHANNEL_CAPACITY: usize = 256;
pub const WORKER_OUTCOME_CHANNEL_CAPACITY: usize = 256;

pub struct ClientEngine {
    commands: mpsc::Sender<EngineCommandEnvelope>,
    events: EngineEventReceiver,
    shutdown: CancellationToken,
}

impl ClientEngine {
    pub fn new(config: EngineConfig) -> EngineResult<Self> {
        Self::new_with_optional_anchor(config, None)
    }

    pub fn new_with_anchor(
        config: EngineConfig,
        anchor: &mut dyn MlsEpochAnchor<Error = EngineError>,
    ) -> EngineResult<Self> {
        Self::new_with_optional_anchor(config, Some(anchor))
    }

    pub fn new_with_owned_anchor(
        config: EngineConfig,
        anchor: Box<dyn MlsEpochAnchor<Error = EngineError> + Send>,
    ) -> EngineResult<Self> {
        Self::new_with_owned_anchor_internal(config, anchor)
    }

    fn new_with_owned_anchor_internal(
        config: EngineConfig,
        anchor: Box<dyn MlsEpochAnchor<Error = EngineError> + Send>,
    ) -> EngineResult<Self> {
        let (command_tx, command_rx) = mpsc::channel(COMMAND_CHANNEL_CAPACITY);
        let (actor_event_tx, mut actor_event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let shutdown = CancellationToken::new();
        let actor = ClientEngineActor::new_with_owned_anchor(config, anchor)?;
        let public_events = event_tx.clone();
        tokio::spawn(async move {
            while let Some(event) = actor_event_rx.recv().await {
                if public_events.send(event).await.is_err() {
                    break;
                }
            }
        });
        let fatal_events = actor_event_tx.clone();
        let actor_shutdown = shutdown.clone();
        tokio::spawn(async move {
            if let Err(error) = actor.run(command_rx, actor_event_tx, actor_shutdown).await {
                let _ = fatal_events
                    .send(EngineEvent::Fatal {
                        error: EngineFatalError {
                            code: "engine_actor_failed".to_owned(),
                            message: error.to_string(),
                        },
                    })
                    .await;
            }
        });
        Ok(Self {
            commands: command_tx,
            events: EngineEventReceiver::new(event_rx),
            shutdown,
        })
    }

    fn new_with_optional_anchor(
        config: EngineConfig,
        mut anchor: Option<&mut dyn MlsEpochAnchor<Error = EngineError>>,
    ) -> EngineResult<Self> {
        let (command_tx, command_rx) = mpsc::channel(COMMAND_CHANNEL_CAPACITY);
        let (actor_event_tx, mut actor_event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let shutdown = CancellationToken::new();
        let mut journal = StartupJournal::open(config.log_directory.as_deref(), &config.platform);
        let actor_result = match anchor.as_deref_mut() {
            Some(anchor) => ClientEngineActor::new_with_anchor(config, anchor),
            None => ClientEngineActor::new(config),
        };
        let actor = match actor_result {
            Ok(actor) => actor,
            Err(error) => {
                journal.record_engine_creation_failure(&error.to_string());
                return Err(error);
            }
        };
        let public_events = event_tx.clone();
        tokio::spawn(async move {
            while let Some(event) = actor_event_rx.recv().await {
                journal.record(&event);
                if public_events.send(event).await.is_err() {
                    break;
                }
            }
        });
        let fatal_events = actor_event_tx.clone();
        let actor_shutdown = shutdown.clone();
        tokio::spawn(async move {
            if let Err(error) = actor.run(command_rx, actor_event_tx, actor_shutdown).await {
                let _ = fatal_events
                    .send(EngineEvent::Fatal {
                        error: EngineFatalError {
                            code: "engine_actor_failed".to_owned(),
                            message: error.to_string(),
                        },
                    })
                    .await;
            }
        });
        Ok(Self {
            commands: command_tx,
            events: EngineEventReceiver::new(event_rx),
            shutdown,
        })
    }

    pub async fn submit(
        &self,
        request_id: impl Into<String>,
        command: EngineCommand,
    ) -> EngineResult<()> {
        self.submit_envelope(EngineCommandEnvelope {
            request_id: request_id.into(),
            command_id: None,
            command,
        })
        .await
    }

    /// Submits a command without discarding its caller-supplied command id.
    ///
    /// FFI hosts use this path because `command_id` participates in durable
    /// idempotency.  Keeping it at the engine boundary also makes a retried
    /// platform request distinguishable from a new command.
    pub async fn submit_envelope(&self, envelope: EngineCommandEnvelope) -> EngineResult<()> {
        self.commands
            .send(envelope)
            .await
            .map_err(|_| EngineError::Closed("engine command channel is closed"))
    }

    pub async fn submit_platform_fact(
        &self,
        request_id: impl Into<String>,
        fact: PlatformFact,
    ) -> EngineResult<()> {
        self.submit(request_id, EngineCommand::PlatformFact { fact })
            .await
    }

    pub fn poll(&mut self) -> Result<crate::EngineEvent, mpsc::error::TryRecvError> {
        self.events.try_recv()
    }

    pub async fn poll_timeout(&mut self, timeout: Duration) -> Option<crate::EngineEvent> {
        self.events.recv_timeout(timeout).await
    }

    pub async fn start(&self) -> EngineResult<()> {
        self.submit("engine-start-bootstrap", EngineCommand::Bootstrap)
            .await
    }

    pub fn shutdown(&self) {
        self.shutdown.cancel();
    }

    pub fn into_parts(
        self,
    ) -> (
        mpsc::Sender<EngineCommandEnvelope>,
        EngineEventReceiver,
        CancellationToken,
    ) {
        (self.commands, self.events, self.shutdown)
    }
}
