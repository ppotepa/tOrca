use tokio::sync::{mpsc, oneshot};
use tokio::time::Duration;
use tokio_util::sync::CancellationToken;

use crate::{
    ClientEngineActor, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError,
    EngineEvent, EngineFatalError, EngineResult, PlatformFact, ResponseResult,
    event::EngineEventReceiver,
    input::{EngineInputEnvelope, EngineInputSource},
    logging::StartupJournal,
    output::{PendingResponseRegistry, spawn_event_router},
};

pub const ENGINE_INBOX_CAPACITY: usize = 512;
pub const COMMAND_CHANNEL_CAPACITY: usize = ENGINE_INBOX_CAPACITY;
pub const WORKER_OUTCOME_CHANNEL_CAPACITY: usize = 256;
const ENGINE_RESPONSE_TIMEOUT: Duration = Duration::from_secs(75);

#[derive(Clone)]
pub struct EngineCommandSender {
    inbox: mpsc::Sender<EngineInputEnvelope>,
    source: EngineInputSource,
}

impl EngineCommandSender {
    pub async fn send(
        &self,
        envelope: EngineCommandEnvelope,
    ) -> Result<(), mpsc::error::SendError<EngineCommandEnvelope>> {
        let mut input = EngineInputEnvelope::command(unix_ms(), envelope);
        if input.source == EngineInputSource::ClientApi {
            input.source = self.source;
        }
        self.inbox.send(input).await.map_err(|error| {
            let envelope = error
                .0
                .into_command_envelope()
                .expect("command sender only submits command or platform inputs");
            mpsc::error::SendError(envelope)
        })
    }

    fn with_source(mut self, source: EngineInputSource) -> Self {
        self.source = source;
        self
    }
}

pub struct ClientEngine {
    commands: EngineCommandSender,
    events: EngineEventReceiver,
    shutdown: CancellationToken,
    pending_responses: PendingResponseRegistry,
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
        let (command_tx, inbox_rx, inbox_tx) = unified_inbox_channel();
        let (actor_event_tx, actor_event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let shutdown = CancellationToken::new();
        let pending_responses = PendingResponseRegistry::default();
        let actor = ClientEngineActor::new_with_owned_anchor(config, anchor)?;
        spawn_event_router(
            actor_event_rx,
            event_tx,
            pending_responses.clone(),
            None,
        );
        let fatal_events = actor_event_tx.clone();
        let actor_shutdown = shutdown.clone();
        tokio::spawn(async move {
            if let Err(error) = actor
                .run_unified(inbox_rx, inbox_tx, actor_event_tx, actor_shutdown)
                .await
            {
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
            pending_responses,
        })
    }

    fn new_with_optional_anchor(
        config: EngineConfig,
        anchor: Option<&mut dyn MlsEpochAnchor<Error = EngineError>>,
    ) -> EngineResult<Self> {
        let (command_tx, inbox_rx, inbox_tx) = unified_inbox_channel();
        let (actor_event_tx, actor_event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(WORKER_OUTCOME_CHANNEL_CAPACITY);
        let shutdown = CancellationToken::new();
        let pending_responses = PendingResponseRegistry::default();
        let mut journal = StartupJournal::open(config.log_directory.as_deref(), &config.platform);
        let actor_result = match anchor {
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
        spawn_event_router(
            actor_event_rx,
            event_tx,
            pending_responses.clone(),
            Some(journal),
        );
        let fatal_events = actor_event_tx.clone();
        let actor_shutdown = shutdown.clone();
        tokio::spawn(async move {
            if let Err(error) = actor
                .run_unified(inbox_rx, inbox_tx, actor_event_tx, actor_shutdown)
                .await
            {
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
            pending_responses,
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
    /// idempotency. Keeping it at the engine boundary also makes a retried
    /// platform request distinguishable from a new command.
    pub async fn submit_envelope(&self, envelope: EngineCommandEnvelope) -> EngineResult<()> {
        self.commands
            .send(envelope)
            .await
            .map_err(|_| EngineError::Closed("engine inbox is closed"))
    }

    pub(crate) async fn submit_and_wait(
        &self,
        command: EngineCommand,
    ) -> EngineResult<ResponseResult> {
        self.submit_with_command_id(command, None).await
    }

    pub(crate) async fn submit_mutation_and_wait(
        &self,
        command: EngineCommand,
        command_id: String,
    ) -> EngineResult<ResponseResult> {
        self.submit_with_command_id(command, Some(command_id)).await
    }

    async fn submit_with_command_id(
        &self,
        command: EngineCommand,
        command_id: Option<String>,
    ) -> EngineResult<ResponseResult> {
        let request_id = format!("client-query-{}", uuid::Uuid::new_v4());
        let (reply_tx, reply_rx) = oneshot::channel();
        self.pending_responses
            .register(request_id.clone(), reply_tx)
            .await;

        if let Err(error) = self
            .submit_envelope(EngineCommandEnvelope {
                request_id: request_id.clone(),
                command_id,
                command,
            })
            .await
        {
            self.pending_responses.remove(&request_id).await;
            return Err(error);
        }

        match tokio::time::timeout(ENGINE_RESPONSE_TIMEOUT, reply_rx).await {
            Ok(Ok(result)) => Ok(result),
            Ok(Err(_)) => Err(EngineError::Closed("engine response channel is closed")),
            Err(_) => {
                self.pending_responses.remove(&request_id).await;
                Err(EngineError::Closed("engine response timed out"))
            }
        }
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
        EngineCommandSender,
        EngineEventReceiver,
        CancellationToken,
    ) {
        (
            self.commands.with_source(EngineInputSource::Ffi),
            self.events,
            self.shutdown,
        )
    }
}

fn unified_inbox_channel() -> (
    EngineCommandSender,
    mpsc::Receiver<EngineInputEnvelope>,
    mpsc::Sender<EngineInputEnvelope>,
) {
    let (inbox_tx, inbox_rx) = mpsc::channel::<EngineInputEnvelope>(ENGINE_INBOX_CAPACITY);
    (
        EngineCommandSender {
            inbox: inbox_tx.clone(),
            source: EngineInputSource::ClientApi,
        },
        inbox_rx,
        inbox_tx,
    )
}

fn unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

use torchat_crypto::anti_rollback::MlsEpochAnchor;
