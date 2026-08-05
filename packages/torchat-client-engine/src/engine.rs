use std::{collections::HashMap, sync::Arc};

use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::Duration;
use tokio_util::sync::CancellationToken;

use crate::{
    ClientEngineActor, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError,
    EngineEvent, EngineFatalError, EngineResult, PlatformFact, ResponseResult,
    event::EngineEventReceiver,
    input::{EngineInput, EngineInputEnvelope},
    logging::StartupJournal,
};

pub const ENGINE_INBOX_CAPACITY: usize = 512;
pub const COMMAND_CHANNEL_CAPACITY: usize = ENGINE_INBOX_CAPACITY;
pub const WORKER_OUTCOME_CHANNEL_CAPACITY: usize = 256;
const ENGINE_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct EngineCommandSender {
    inbox: mpsc::Sender<EngineInputEnvelope>,
}

impl EngineCommandSender {
    pub async fn send(
        &self,
        envelope: EngineCommandEnvelope,
    ) -> Result<(), mpsc::error::SendError<EngineCommandEnvelope>> {
        let input = EngineInputEnvelope::command(unix_ms(), envelope);
        self.inbox.send(input).await.map_err(|error| {
            let EngineInput::Command(envelope) = error.0.input else {
                unreachable!("command sender only submits command inputs");
            };
            mpsc::error::SendError(envelope)
        })
    }
}

pub struct ClientEngine {
    commands: EngineCommandSender,
    events: EngineEventReceiver,
    shutdown: CancellationToken,
    pending_responses: Arc<Mutex<HashMap<String, oneshot::Sender<ResponseResult>>>>,
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
        let pending_responses: Arc<Mutex<HashMap<String, oneshot::Sender<ResponseResult>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let actor = ClientEngineActor::new_with_owned_anchor(config, anchor)?;
        spawn_event_router(
            actor_event_rx,
            event_tx,
            Arc::clone(&pending_responses),
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
        let pending_responses: Arc<Mutex<HashMap<String, oneshot::Sender<ResponseResult>>>> =
            Arc::new(Mutex::new(HashMap::new()));
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
            Arc::clone(&pending_responses),
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
            .lock()
            .await
            .insert(request_id.clone(), reply_tx);

        if let Err(error) = self
            .submit_envelope(EngineCommandEnvelope {
                request_id: request_id.clone(),
                command_id,
                command,
            })
            .await
        {
            self.pending_responses.lock().await.remove(&request_id);
            return Err(error);
        }

        match tokio::time::timeout(ENGINE_RESPONSE_TIMEOUT, reply_rx).await {
            Ok(Ok(result)) => Ok(result),
            Ok(Err(_)) => Err(EngineError::Closed("engine response channel is closed")),
            Err(_) => {
                self.pending_responses.lock().await.remove(&request_id);
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
        (self.commands, self.events, self.shutdown)
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
        },
        inbox_rx,
        inbox_tx,
    )
}

fn spawn_event_router(
    mut actor_events: mpsc::Receiver<EngineEvent>,
    public_events: mpsc::Sender<EngineEvent>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<ResponseResult>>>>,
    mut journal: Option<StartupJournal>,
) {
    let (publish_tx, mut publish_rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Some(event) = actor_events.recv().await {
            if let Some(journal) = journal.as_mut() {
                journal.record(&event);
            }
            if let EngineEvent::Response { request_id, result } = &event
                && let Some(reply) = pending.lock().await.remove(request_id)
            {
                let _ = reply.send(result.clone());
            }
            if publish_tx.send(event).is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        while let Some(event) = publish_rx.recv().await {
            if public_events.send(event).await.is_err() {
                break;
            }
        }
    });
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
