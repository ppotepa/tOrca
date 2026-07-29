use tokio::sync::mpsc;
use tokio::time::Duration;
use tokio_util::sync::CancellationToken;

use crate::{
    ClientEngineActor, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError,
    EngineEvent, EngineFatalError, EngineResult, PlatformFact, event::EngineEventReceiver,
};

pub struct ClientEngine {
    commands: mpsc::Sender<EngineCommandEnvelope>,
    events: EngineEventReceiver,
    shutdown: CancellationToken,
}

impl ClientEngine {
    pub fn new(config: EngineConfig) -> EngineResult<Self> {
        let (command_tx, command_rx) = mpsc::channel(64);
        let (event_tx, event_rx) = mpsc::channel(256);
        let shutdown = CancellationToken::new();
        let actor = ClientEngineActor::new(config)?;
        let fatal_events = event_tx.clone();
        let actor_shutdown = shutdown.clone();
        tokio::spawn(async move {
            if let Err(error) = actor.run(command_rx, event_tx, actor_shutdown).await {
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
        self.commands
            .send(EngineCommandEnvelope {
                request_id: request_id.into(),
                command,
            })
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
