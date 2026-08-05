use super::*;

use std::collections::VecDeque;
use tokio::sync::watch;

use crate::{
    effects::spawn_engine_effect,
    input::{EngineInput, EngineInputEnvelope},
    processing::EngineProcessingResult,
    scheduler::spawn_engine_scheduler,
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
        spawn_peer_ingress(peer_events, inbox_tx.clone(), shutdown.clone());
        spawn_shutdown_ingress(shutdown.clone(), inbox_tx.clone());

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
        spawn_engine_scheduler(scheduler_rx, inbox_tx.clone(), shutdown.clone());
        let mut derived_inputs = VecDeque::new();

        loop {
            let envelope = match derived_inputs.pop_front() {
                Some(envelope) => envelope,
                None => {
                    let Some(envelope) = inbox.recv().await else {
                        break;
                    };
                    envelope
                }
            };
            let mut result = self.process_unified_input(envelope, scheduler_generation)?;
            let plan_changed = result.scheduler_plan_changed;
            let should_stop = result.should_stop();
            let effects = std::mem::take(&mut result.effects);
            derived_inputs.extend(std::mem::take(&mut result.derived_inputs));
            publish_events(&events, result.events).await;
            for effect in effects {
                spawn_engine_effect(effect, inbox_tx.clone());
            }

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
        let input_id = envelope.input_id;
        match envelope.input {
            EngineInput::Command(command) => Ok(self.process_command_input(input_id, command)),
            EngineInput::PeerEvent(event) => Ok(self.process_peer_input(event)),
            EngineInput::RelayEvent(event) => Ok(self.process_relay_input(event)),
            EngineInput::PlatformFact { request, fact } => {
                Ok(self.process_platform_input(request, fact))
            }
            EngineInput::TimerElapsed { kind, generation } => {
                if generation != scheduler_generation {
                    return Ok(EngineProcessingResult::empty());
                }
                self.process_timer_input(input_id, kind)
            }
            EngineInput::EffectOutcome(outcome) => Ok(self.process_effect_outcome(outcome)),
            EngineInput::ShutdownRequested => Ok(self.process_shutdown_input()),
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
