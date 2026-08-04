use std::{
    collections::HashMap,
    sync::mpsc as std_mpsc,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use reqwest::Url;
use torchat_client_runtime::{InviteCode, InviteState, PairingItem, RuntimeError, RuntimeResult};
use torchat_core::{
    ContactInvite, Identity,
    relay::RelayPayloadV1,
    rendezvous::{RendezvousClientFrame, RendezvousServerFrame},
    rendezvous_crypto,
};
use uuid::Uuid;

enum RendezvousEvent {
    Frame(RendezvousServerFrame),
    Error(String),
}

use super::{EngineRelay, RelayEvent};

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Compatibility shell for the old engine wiring. Relay sessions and
/// application envelopes were deliberately removed: direct contacts use the
/// peer transport and pairing uses `PairingRendezvousClient`.
pub struct SharedRelayActor {
    pub connection: super::RelayConnectionConfig,
    pub writer: super::RelayWriterConfig,
    pub heartbeat: super::RelayHeartbeatConfig,
    _identity: Identity,
    commands: Option<tokio::sync::mpsc::UnboundedSender<RendezvousClientFrame>>,
    events: Option<std_mpsc::Receiver<RendezvousEvent>>,
    owner_tokens: HashMap<Uuid, String>,
    joiner_tokens: HashMap<Uuid, String>,
    invite_pairings: HashMap<String, Uuid>,
    rendezvous_private_keys: HashMap<String, [u8; 32]>,
    pairing_private_keys: HashMap<Uuid, [u8; 32]>,
    pairing_peer_keys: HashMap<Uuid, [u8; 32]>,
    active_slot: Option<(String, String)>,
}

impl SharedRelayActor {
    pub fn new(relay_onion_url: Url, socks5_url: Option<String>, identity: Identity) -> Self {
        Self {
            connection: super::RelayConnectionConfig {
                connect_timeout: Duration::from_secs(10),
                ready_timeout: Duration::from_secs(15),
                socks5_url,
                relay_onion_url: relay_onion_url.to_string(),
            },
            writer: super::RelayWriterConfig {
                control_channel_capacity: 32,
                data_channel_capacity: 32,
            },
            heartbeat: super::RelayHeartbeatConfig {
                ping_interval: Duration::from_secs(25),
                pong_timeout: Duration::from_secs(60),
            },
            _identity: identity,
            commands: None,
            events: None,
            owner_tokens: HashMap::new(),
            joiner_tokens: HashMap::new(),
            invite_pairings: HashMap::new(),
            rendezvous_private_keys: HashMap::new(),
            pairing_private_keys: HashMap::new(),
            pairing_peer_keys: HashMap::new(),
            active_slot: None,
        }
    }

    fn removed<T>() -> RuntimeResult<T> {
        Err(RuntimeError::Unavailable(
            "legacy relay control plane was removed; use rendezvous pairing".to_owned(),
        ))
    }

    fn start_rendezvous(&mut self) -> RuntimeResult<()> {
        if self.commands.is_some() {
            return Ok(());
        }
        let socks5 = self.connection.socks5_url.clone().ok_or_else(|| {
            RuntimeError::Unavailable("Tor SOCKS endpoint is not ready".to_owned())
        })?;
        let relay_url = Url::parse(&self.connection.relay_onion_url)
            .map_err(|e| RuntimeError::InvalidCommand(e.to_string()))?;
        let (command_tx, mut command_rx) = tokio::sync::mpsc::unbounded_channel();
        let (event_tx, event_rx) = std_mpsc::channel();
        thread::spawn(move || {
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                let _ = event_tx.send(RendezvousEvent::Error(
                    "rendezvous runtime unavailable".to_owned(),
                ));
                return;
            };
            runtime.block_on(async move {
                let mut client = match super::rendezvous::PairingRendezvousClient::connect(relay_url, Some(&socks5)).await {
                    Ok(client) => client,
                    Err(error) => {
                        let _ = event_tx.send(RendezvousEvent::Error(format!("rendezvous connect failed: {error}")));
                        return;
                    }
                };
                loop {
                    tokio::select! {
                        Some(command) = command_rx.recv() => {
                            if let Err(error) = client.send(command).await {
                                let _ = event_tx.send(RendezvousEvent::Error(format!("rendezvous send failed: {error}")));
                                break;
                            }
                        }
                        result = client.next() => {
                            match result {
                                Ok(frame) => { if event_tx.send(RendezvousEvent::Frame(frame)).is_err() { break; } }
                                Err(error) => {
                                    let _ = event_tx.send(RendezvousEvent::Error(format!("rendezvous receive failed: {error}")));
                                    break;
                                }
                            }
                        }
                    }
                }
            });
        });
        self.commands = Some(command_tx);
        self.events = Some(event_rx);
        Ok(())
    }

    fn send_frame(&mut self, frame: RendezvousClientFrame) -> RuntimeResult<()> {
        self.start_rendezvous()?;
        let result = self
            .commands
            .as_ref()
            .ok_or_else(|| RuntimeError::Unavailable("rendezvous worker unavailable".into()))?
            .send(frame);
        if result.is_err() {
            self.commands = None;
            self.events = None;
            return Err(RuntimeError::Unavailable(
                "rendezvous connection closed".into(),
            ));
        }
        Ok(())
    }

    fn receive_frame(&mut self) -> RuntimeResult<RendezvousServerFrame> {
        match self
            .events
            .as_ref()
            .ok_or_else(|| RuntimeError::Unavailable("rendezvous worker unavailable".into()))?
            .recv_timeout(Duration::from_secs(30))
            .map_err(|e| RuntimeError::Unavailable(format!("rendezvous response timeout: {e}")))?
        {
            RendezvousEvent::Frame(frame) => Ok(frame),
            RendezvousEvent::Error(error) => {
                self.commands = None;
                self.events = None;
                Err(RuntimeError::Unavailable(error))
            }
        }
    }

    pub fn submit_pairing_code_with_offer(
        &mut self,
        code: &str,
        pairing_id: Uuid,
        offer: String,
    ) -> RuntimeResult<PairingItem> {
        self.start_rendezvous()?;
        let request_id = Uuid::new_v4();
        self.send_frame(RendezvousClientFrame::ResolvePairingCode {
            request_id,
            display_code: code.to_owned(),
        })?;
        let (slot_handle, _owner_key) = match self.receive_frame()? {
            RendezvousServerFrame::PairingSlotResolved {
                request_id: received,
                slot_handle,
                owner_rendezvous_public_key,
                ..
            } if received == request_id => (slot_handle, owner_rendezvous_public_key),
            RendezvousServerFrame::Error { code, .. } => {
                return Err(RuntimeError::Unavailable(code));
            }
            _ => {
                return Err(RuntimeError::Unavailable(
                    "unexpected rendezvous response".into(),
                ));
            }
        };
        if let Ok(RelayPayloadV1::PairingOffer { invite, .. }) = RelayPayloadV1::decode(&offer) {
            if let Ok(invite) = ContactInvite::parse(&invite) {
                self.invite_pairings.insert(invite.invite_id, pairing_id);
            }
        }
        let mut joiner_key = [0_u8; 32];
        getrandom::fill(&mut joiner_key).map_err(|e| RuntimeError::Unavailable(e.to_string()))?;
        self.pairing_private_keys.insert(pairing_id, joiner_key);
        self.pairing_peer_keys.insert(pairing_id, _owner_key);
        let encrypted_offer = rendezvous_crypto::seal(joiner_key, _owner_key, offer.as_bytes())
            .map_err(RuntimeError::Unavailable)?;
        self.send_frame(RendezvousClientFrame::BeginPairing {
            request_id: Uuid::new_v4(),
            pairing_id,
            slot_handle,
            joiner_rendezvous_public_key: rendezvous_crypto::public_key(joiner_key),
            encrypted_offer,
        })?;
        let (started, token) = match self.receive_frame()? {
            RendezvousServerFrame::PairingStarted {
                pairing_id: started,
                joiner_side_token,
                ..
            } => (started, joiner_side_token),
            RendezvousServerFrame::Error { code, .. } => {
                return Err(RuntimeError::Unavailable(code));
            }
            _ => {
                return Err(RuntimeError::Unavailable(
                    "unexpected rendezvous response".into(),
                ));
            }
        };
        self.joiner_tokens.insert(started, token);
        Ok(PairingItem {
            pairing_id: started.to_string(),
            sender: None,
            capability: None,
            expires_at: unix_now() + 180,
            state: InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        })
    }
}

impl EngineRelay for SharedRelayActor {
    fn set_socks5_url(&mut self, socks5_url: Option<String>) {
        if self.connection.socks5_url != socks5_url {
            // The rendezvous worker captures the SOCKS endpoint at startup.
            // Drop it when Tor rotates/restarts so the next pairing attempt
            // reconnects through the current endpoint.
            self.commands = None;
            self.events = None;
        }
        self.connection.socks5_url = socks5_url;
    }

    fn shutdown(&mut self) {}

    fn ensure_session(&mut self) -> RuntimeResult<()> {
        Ok(())
    }

    fn send_envelope(
        &mut self,
        message_id: uuid::Uuid,
        _recipient: &str,
        ciphertext: &str,
    ) -> RuntimeResult<()> {
        let payload = RelayPayloadV1::decode(ciphertext).map_err(RuntimeError::InvalidCommand)?;
        match payload {
            RelayPayloadV1::PairingRejected { .. } => {
                let token = self
                    .owner_tokens
                    .get(&message_id)
                    .or_else(|| self.joiner_tokens.get(&message_id))
                    .cloned()
                    .ok_or_else(|| {
                        RuntimeError::Unavailable("pairing side token missing".into())
                    })?;
                self.send_frame(RendezvousClientFrame::RejectPairing {
                    pairing_id: message_id,
                    side_token: token,
                })
            }
            RelayPayloadV1::WelcomeApplied { invite_id, .. } => {
                let pairing_id = self
                    .invite_pairings
                    .get(&invite_id)
                    .copied()
                    .unwrap_or(message_id);
                let token = self
                    .joiner_tokens
                    .get(&pairing_id)
                    .cloned()
                    .ok_or_else(|| {
                        RuntimeError::Unavailable("pairing side token missing".into())
                    })?;
                self.send_frame(RendezvousClientFrame::PairingCommitted {
                    pairing_id,
                    side_token: token,
                })
            }
            _ => {
                let token = self.owner_tokens.get(&message_id).cloned().ok_or_else(|| {
                    RuntimeError::Unavailable("pairing owner token missing".into())
                })?;
                let private_key = self
                    .pairing_private_keys
                    .get(&message_id)
                    .copied()
                    .ok_or_else(|| {
                        RuntimeError::Unavailable("rendezvous private key missing".into())
                    })?;
                let peer_key = self
                    .pairing_peer_keys
                    .get(&message_id)
                    .copied()
                    .ok_or_else(|| RuntimeError::Unavailable("pairing peer key missing".into()))?;
                let encrypted_response =
                    rendezvous_crypto::seal(private_key, peer_key, ciphertext.as_bytes())
                        .map_err(RuntimeError::Unavailable)?;
                self.send_frame(RendezvousClientFrame::AcceptPairing {
                    pairing_id: message_id,
                    side_token: token,
                    encrypted_response,
                })
            }
        }
    }

    fn poll_event(&mut self) -> Option<RelayEvent> {
        let event = self.events.as_ref()?.try_recv().ok()?;
        let RendezvousEvent::Frame(frame) = event else {
            self.commands = None;
            self.events = None;
            return None;
        };
        match frame {
            RendezvousServerFrame::PairingRequested {
                pairing_id,
                slot_handle,
                owner_side_token,
                joiner_rendezvous_public_key,
                encrypted_offer,
                ..
            } => {
                self.owner_tokens.insert(pairing_id, owner_side_token);
                self.pairing_peer_keys
                    .insert(pairing_id, joiner_rendezvous_public_key);
                let private_key = self.rendezvous_private_keys.get(&slot_handle).copied()?;
                self.pairing_private_keys.insert(pairing_id, private_key);
                let offer = rendezvous_crypto::open(
                    private_key,
                    joiner_rendezvous_public_key,
                    &encrypted_offer,
                )
                .ok()?;
                Some(RelayEvent::Envelope(envelope_for_payload(
                    pairing_id,
                    String::from_utf8(offer).ok()?,
                )))
            }
            RendezvousServerFrame::PairingAccepted {
                pairing_id,
                encrypted_response,
            } => {
                let private_key = self.pairing_private_keys.get(&pairing_id).copied()?;
                let peer_key = self.pairing_peer_keys.get(&pairing_id).copied()?;
                let response =
                    rendezvous_crypto::open(private_key, peer_key, &encrypted_response).ok()?;
                Some(RelayEvent::Envelope(envelope_for_payload(
                    pairing_id,
                    String::from_utf8(response).ok()?,
                )))
            }
            RendezvousServerFrame::PairingRejected { pairing_id } => {
                Some(RelayEvent::PairingAvailable { pairing_id })
            }
            RendezvousServerFrame::PairingFinalized { pairing_id } => {
                Some(RelayEvent::PairingFinalized { pairing_id })
            }
            _ => None,
        }
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        self.start_rendezvous()?;
        if let Some((slot_handle, slot_capability)) = self.active_slot.take() {
            self.send_frame(RendezvousClientFrame::CancelPairingSlot {
                slot_handle,
                slot_capability,
            })?;
        }
        let request_id = Uuid::new_v4();
        let mut rendezvous_key = [0_u8; 32];
        getrandom::fill(&mut rendezvous_key)
            .map_err(|e| RuntimeError::Unavailable(e.to_string()))?;
        self.send_frame(RendezvousClientFrame::CreatePairingSlot {
            request_id,
            rendezvous_public_key: rendezvous_crypto::public_key(rendezvous_key),
            requested_ttl_seconds: 120,
        })?;
        match self.receive_frame()? {
            RendezvousServerFrame::PairingSlotCreated {
                request_id: received,
                slot_handle,
                display_code,
                slot_capability,
                expires_at_unix,
                ..
            } if received == request_id => {
                self.rendezvous_private_keys
                    .insert(slot_handle.clone(), rendezvous_key);
                self.active_slot = Some((slot_handle, slot_capability));
                Ok(InviteCode {
                    code: display_code,
                    expires_at: expires_at_unix,
                })
            }
            RendezvousServerFrame::Error { code, .. } => Err(RuntimeError::Unavailable(code)),
            _ => Self::removed(),
        }
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        Self::removed()
    }

    fn submit_pairing_code_with_offer(
        &mut self,
        code: &str,
        pairing_id: Uuid,
        offer: String,
    ) -> RuntimeResult<PairingItem> {
        SharedRelayActor::submit_pairing_code_with_offer(self, code, pairing_id, offer)
    }

    fn cancel_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        let pairing_id =
            Uuid::parse_str(pairing_id).map_err(|e| RuntimeError::InvalidCommand(e.to_string()))?;
        if let Some(token) = self.joiner_tokens.get(&pairing_id).cloned() {
            return self.send_frame(RendezvousClientFrame::CancelPairing {
                pairing_id,
                side_token: token,
            });
        }
        if let Some(token) = self.owner_tokens.get(&pairing_id).cloned() {
            return self.send_frame(RendezvousClientFrame::CancelPairing {
                pairing_id,
                side_token: token,
            });
        }
        Self::removed()
    }
}

fn envelope_for_payload(
    message_id: Uuid,
    ciphertext: String,
) -> torchat_core::relay::RelayEnvelope {
    let (sender, recipient) = match RelayPayloadV1::decode(&ciphertext) {
        Ok(RelayPayloadV1::Welcome {
            sender, recipient, ..
        })
        | Ok(RelayPayloadV1::WelcomeApplied {
            sender, recipient, ..
        }) => (sender.installation_id, recipient),
        _ => (String::new(), String::new()),
    };
    torchat_core::relay::RelayEnvelope {
        version: torchat_core::PROTOCOL_VERSION,
        message_id,
        sender,
        recipient,
        ciphertext,
    }
}
