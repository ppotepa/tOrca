use axum::{
    Router,
    extract::{
        WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::IntoResponse,
    routing::get,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use rand::{Rng, rng};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;
use torchat_core::rendezvous::{
    MAX_PAIRING_BLOB_BYTES, RendezvousClientFrame, RendezvousServerFrame,
};
use uuid::Uuid;

const SLOT_TTL: Duration = Duration::from_secs(120);
const BRIDGE_TTL: Duration = Duration::from_secs(180);
const MAX_CONNECTIONS: usize = 2_000;
const MAX_SLOTS: usize = 1_000;
const MAX_SLOTS_PER_CONNECTION: usize = 2;
const MAX_PAIRINGS_PER_CONNECTION: usize = 2;
const MAX_FRAME_BYTES: usize = 64 * 1024;
const MAX_CODE_ATTEMPTS: usize = 5;

type ConnectionId = Uuid;

#[derive(Clone)]
struct AppState {
    actor: mpsc::Sender<Command>,
}

enum Command {
    Connected {
        id: ConnectionId,
        outbound: mpsc::Sender<RendezvousServerFrame>,
    },
    Disconnected {
        id: ConnectionId,
    },
    Frame {
        id: ConnectionId,
        frame: RendezvousClientFrame,
    },
}

struct Connection {
    outbound: mpsc::Sender<RendezvousServerFrame>,
    slots: usize,
    pairings: usize,
    attempts: Vec<i64>,
}
struct Slot {
    owner: ConnectionId,
    handle: String,
    capability_hash: [u8; 32],
    code_hash: [u8; 32],
    rendezvous_public_key: [u8; 32],
    expires_at: i64,
}
struct Bridge {
    owner: ConnectionId,
    joiner: ConnectionId,
    owner_token_hash: [u8; 32],
    joiner_token_hash: [u8; 32],
    slot_hash: [u8; 32],
    expires_at: i64,
}

#[derive(Clone, Default, Serialize)]
struct Metrics {
    active_connections: usize,
    active_pairing_slots: usize,
    active_pairing_bridges: usize,
    rejected_frames: u64,
    expired_slots: u64,
}

#[derive(Clone)]
struct MetricsState(std::sync::Arc<tokio::sync::RwLock<Metrics>>);

#[tokio::main]
async fn main() {
    let (tx, rx) = mpsc::channel(4096);
    let metrics = MetricsState(std::sync::Arc::new(tokio::sync::RwLock::new(
        Metrics::default(),
    )));
    tokio::spawn(run_actor(rx, metrics.clone()));
    let state = AppState { actor: tx };
    let app = Router::new()
        .route("/health", get(health))
        .route("/rendezvous", get(rendezvous))
        .with_state((state, metrics));
    let address: SocketAddr = std::env::var("TORCHAT_BIND")
        .unwrap_or_else(|_| "0.0.0.0:8080".into())
        .parse()
        .expect("TORCHAT_BIND must be valid");
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind relay listener");
    axum::serve(listener, app).await.expect("serve relay");
}

async fn health() -> impl IntoResponse {
    (axum::http::StatusCode::OK, "ok")
}
async fn rendezvous(
    ws: WebSocketUpgrade,
    axum::extract::State((state, _)): axum::extract::State<(AppState, MetricsState)>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| connection(socket, state))
}

async fn connection(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    let id = Uuid::new_v4();
    let (out_tx, mut out_rx) = mpsc::channel(32);
    if state
        .actor
        .send(Command::Connected {
            id,
            outbound: out_tx,
        })
        .await
        .is_err()
    {
        return;
    }
    let writer = tokio::spawn(async move {
        while let Some(frame) = out_rx.recv().await {
            let Ok(bytes) = serde_json::to_vec(&frame) else {
                break;
            };
            if sink.send(Message::Binary(bytes.into())).await.is_err() {
                break;
            }
        }
    });
    while let Some(Ok(message)) = stream.next().await {
        let bytes = match message {
            Message::Binary(bytes) if bytes.len() <= MAX_FRAME_BYTES => bytes,
            Message::Text(text) if text.len() <= MAX_FRAME_BYTES => text.as_bytes().to_vec().into(),
            Message::Ping(_) => {
                let _ = state
                    .actor
                    .send(Command::Frame {
                        id,
                        frame: RendezvousClientFrame::Ping,
                    })
                    .await;
                continue;
            }
            Message::Close(_) => break,
            _ => break,
        };
        let Ok(frame) = serde_json::from_slice::<RendezvousClientFrame>(&bytes) else {
            break;
        };
        if state
            .actor
            .send(Command::Frame { id, frame })
            .await
            .is_err()
        {
            break;
        }
    }
    let _ = state.actor.send(Command::Disconnected { id }).await;
    writer.abort();
}

async fn run_actor(mut rx: mpsc::Receiver<Command>, metrics: MetricsState) {
    let mut connections: HashMap<ConnectionId, Connection> = HashMap::new();
    let mut slots: HashMap<[u8; 32], Slot> = HashMap::new();
    let mut bridges: HashMap<Uuid, Bridge> = HashMap::new();
    let mut ticker = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            Some(command) = rx.recv() => handle_command(command, &mut connections, &mut slots, &mut bridges, &metrics).await,
            _ = ticker.tick() => {
                let now = unix_now();
                expire_state(&mut connections, &mut slots, &mut bridges, now, &metrics).await;
                sync_metrics(&connections, &slots, &bridges, &metrics).await;
            }
        }
    }
}

async fn handle_command(
    command: Command,
    connections: &mut HashMap<ConnectionId, Connection>,
    slots: &mut HashMap<[u8; 32], Slot>,
    bridges: &mut HashMap<Uuid, Bridge>,
    metrics: &MetricsState,
) {
    match command {
        Command::Connected { id, outbound } => {
            if connections.len() < MAX_CONNECTIONS {
                connections.insert(
                    id,
                    Connection {
                        outbound,
                        slots: 0,
                        pairings: 0,
                        attempts: Vec::new(),
                    },
                );
            }
        }
        Command::Disconnected { id } => {
            connections.remove(&id);
            slots.retain(|_, slot| slot.owner != id);
            let removed_ids: Vec<Uuid> = bridges
                .iter()
                .filter(|(_, bridge)| bridge.owner == id || bridge.joiner == id)
                .map(|(pairing_id, _)| *pairing_id)
                .collect();
            let removed_pairings: Vec<Bridge> = removed_ids
                .into_iter()
                .filter_map(|pairing_id| bridges.remove(&pairing_id))
                .collect();
            for bridge in removed_pairings {
                for peer in [bridge.owner, bridge.joiner] {
                    if let Some(connection) = connections.get_mut(&peer) {
                        connection.pairings = connection.pairings.saturating_sub(1);
                    }
                }
            }
        }
        Command::Frame { id, frame } => {
            process_frame(id, frame, connections, slots, bridges, metrics).await
        }
    }
    sync_metrics(connections, slots, bridges, metrics).await;
}

async fn expire_state(
    connections: &mut HashMap<ConnectionId, Connection>,
    slots: &mut HashMap<[u8; 32], Slot>,
    bridges: &mut HashMap<Uuid, Bridge>,
    now: i64,
    metrics: &MetricsState,
) {
    let expired_slots = slots.values().filter(|slot| slot.expires_at <= now).count();
    slots.retain(|_, slot| slot.expires_at > now);
    let expired_ids: Vec<Uuid> = bridges
        .iter()
        .filter(|(_, bridge)| bridge.expires_at <= now)
        .map(|(pairing_id, _)| *pairing_id)
        .collect();
    let expired_bridges: Vec<Bridge> = expired_ids
        .into_iter()
        .filter_map(|pairing_id| bridges.remove(&pairing_id))
        .collect();
    for bridge in expired_bridges {
        for peer in [bridge.owner, bridge.joiner] {
            if let Some(connection) = connections.get_mut(&peer) {
                connection.pairings = connection.pairings.saturating_sub(1);
            }
        }
    }
    if expired_slots > 0 {
        metrics.0.write().await.expired_slots += expired_slots as u64;
    }
}

async fn process_frame(
    id: ConnectionId,
    frame: RendezvousClientFrame,
    connections: &mut HashMap<ConnectionId, Connection>,
    slots: &mut HashMap<[u8; 32], Slot>,
    bridges: &mut HashMap<Uuid, Bridge>,
    metrics: &MetricsState,
) {
    if !connections.contains_key(&id) {
        return;
    }
    match frame {
        RendezvousClientFrame::Ping => send(connections, id, RendezvousServerFrame::Pong).await,
        RendezvousClientFrame::CreatePairingSlot {
            request_id,
            rendezvous_public_key,
            requested_ttl_seconds,
        } => {
            if connections[&id].slots >= MAX_SLOTS_PER_CONNECTION || slots.len() >= MAX_SLOTS {
                reject(connections, metrics, id, Some(request_id), "capacity").await;
                return;
            }
            let ttl =
                Duration::from_secs(u64::from(requested_ttl_seconds).clamp(10, SLOT_TTL.as_secs()));
            let code = generate_code();
            let handle = random_token();
            let capability = random_token();
            slots.insert(
                hash(&handle),
                Slot {
                    owner: id,
                    handle: handle.clone(),
                    capability_hash: hash(&capability),
                    code_hash: hash(&code),
                    rendezvous_public_key,
                    expires_at: unix_now() + ttl.as_secs() as i64,
                },
            );
            connections.get_mut(&id).unwrap().slots += 1;
            send(
                connections,
                id,
                RendezvousServerFrame::PairingSlotCreated {
                    request_id,
                    slot_handle: handle,
                    display_code: code,
                    slot_capability: capability,
                    expires_at_unix: unix_now() + ttl.as_secs() as i64,
                },
            )
            .await;
        }
        RendezvousClientFrame::ResolvePairingCode {
            request_id,
            display_code,
        } => {
            let now = unix_now();
            let c = connections.get_mut(&id).unwrap();
            c.attempts.retain(|t| *t + 60 > now);
            if c.attempts.len() >= MAX_CODE_ATTEMPTS {
                reject(connections, metrics, id, Some(request_id), "rate_limited").await;
                return;
            }
            c.attempts.push(now);
            let Some(slot) = slots
                .values()
                .find(|slot| slot.code_hash == hash(&display_code) && slot.expires_at > now)
            else {
                reject(connections, metrics, id, Some(request_id), "invalid_code").await;
                return;
            };
            send(
                connections,
                id,
                RendezvousServerFrame::PairingSlotResolved {
                    request_id,
                    slot_handle: slot.handle.clone(),
                    owner_rendezvous_public_key: slot.rendezvous_public_key,
                    expires_at_unix: slot.expires_at,
                },
            )
            .await;
        }
        RendezvousClientFrame::BeginPairing {
            request_id,
            pairing_id,
            slot_handle,
            joiner_rendezvous_public_key,
            encrypted_offer,
        } => {
            if encrypted_offer.len() > MAX_PAIRING_BLOB_BYTES {
                reject(connections, metrics, id, Some(request_id), "blob_too_large").await;
                return;
            }
            let slot_hash = hash(&slot_handle);
            let Some(slot) = slots.get(&slot_hash) else {
                reject(connections, metrics, id, Some(request_id), "invalid_slot").await;
                return;
            };
            if slot.expires_at <= unix_now() || slot.owner == id {
                reject(connections, metrics, id, Some(request_id), "invalid_slot").await;
                return;
            }
            if bridges.contains_key(&pairing_id) {
                reject(connections, metrics, id, Some(request_id), "duplicate_pairing").await;
                return;
            }
            if connections[&id].pairings >= MAX_PAIRINGS_PER_CONNECTION
                || connections[&slot.owner].pairings >= MAX_PAIRINGS_PER_CONNECTION
            {
                reject(connections, metrics, id, Some(request_id), "capacity").await;
                return;
            }
            let owner_token = random_token();
            let joiner_token = random_token();
            let owner = slot.owner;
            let slot_handle_for_owner = slot.handle.clone();
            let expires_at = slot.expires_at;
            let owner_rendezvous_public_key = slot.rendezvous_public_key;
            slots.remove(&slot_hash);
            if let Some(c) = connections.get_mut(&owner) {
                c.slots = c.slots.saturating_sub(1);
            }
            bridges.insert(
                pairing_id,
                Bridge {
                    owner,
                    joiner: id,
                    owner_token_hash: hash(&owner_token),
                    joiner_token_hash: hash(&joiner_token),
                    slot_hash,
                    expires_at: unix_now() + BRIDGE_TTL.as_secs() as i64,
                },
            );
            connections.get_mut(&id).unwrap().pairings += 1;
            connections.get_mut(&owner).unwrap().pairings += 1;
            send(
                connections,
                owner,
                RendezvousServerFrame::PairingRequested {
                    pairing_id,
                    slot_handle: slot_handle_for_owner,
                    owner_side_token: owner_token,
                    joiner_rendezvous_public_key,
                    encrypted_offer,
                    expires_at_unix: unix_now() + BRIDGE_TTL.as_secs() as i64,
                },
            )
            .await;
            let _ = (expires_at, owner_rendezvous_public_key);
            send(
                connections,
                id,
                RendezvousServerFrame::PairingStarted {
                    request_id,
                    pairing_id,
                    joiner_side_token: joiner_token,
                    expires_at_unix: unix_now() + BRIDGE_TTL.as_secs() as i64,
                },
            )
            .await;
        }
        RendezvousClientFrame::AcceptPairing {
            pairing_id,
            side_token,
            encrypted_response,
        } => {
            if let Some(bridge) = bridges.get(&pairing_id) {
                if bridge.owner == id
                    && bridge.owner_token_hash == hash(&side_token)
                    && encrypted_response.len() <= MAX_PAIRING_BLOB_BYTES
                {
                    send(
                        connections,
                        bridge.joiner,
                        RendezvousServerFrame::PairingAccepted {
                            pairing_id,
                            encrypted_response,
                        },
                    )
                    .await;
                }
            }
        }
        RendezvousClientFrame::RejectPairing {
            pairing_id,
            side_token,
        } => {
            if authorize_either(bridges.get(&pairing_id), id, &side_token) {
                finish_pairing(
                    pairing_id,
                    connections,
                    slots,
                    bridges,
                    RendezvousServerFrame::PairingRejected { pairing_id },
                )
                .await;
            }
        }
        RendezvousClientFrame::PairingCommitted {
            pairing_id,
            side_token,
        } => {
            if authorize(bridges.get(&pairing_id), id, &side_token, false) {
                finish_pairing(
                    pairing_id,
                    connections,
                    slots,
                    bridges,
                    RendezvousServerFrame::PairingFinalized { pairing_id },
                )
                .await;
            }
        }
        RendezvousClientFrame::PairingFinalized {
            pairing_id,
            side_token,
        } => {
            if authorize(bridges.get(&pairing_id), id, &side_token, true) {
                finish_pairing(
                    pairing_id,
                    connections,
                    slots,
                    bridges,
                    RendezvousServerFrame::PairingFinalized { pairing_id },
                )
                .await;
            }
        }
        RendezvousClientFrame::CancelPairing {
            pairing_id,
            side_token,
        } => {
            if authorize_either(bridges.get(&pairing_id), id, &side_token) {
                finish_pairing(
                    pairing_id,
                    connections,
                    slots,
                    bridges,
                    RendezvousServerFrame::PairingCancelled { pairing_id },
                )
                .await;
            }
        }
        RendezvousClientFrame::CancelPairingSlot {
            slot_handle,
            slot_capability,
        } => {
            let key = hash(&slot_handle);
            if slots.get(&key).is_some_and(|slot| {
                slot.owner == id && slot.capability_hash == hash(&slot_capability)
            }) {
                slots.remove(&key);
                if let Some(c) = connections.get_mut(&id) {
                    c.slots = c.slots.saturating_sub(1);
                }
            }
        }
    }
}

fn authorize(bridge: Option<&Bridge>, id: ConnectionId, token: &str, owner: bool) -> bool {
    bridge.is_some_and(|b| {
        (owner && b.owner == id && b.owner_token_hash == hash(token))
            || (!owner && b.joiner == id && b.joiner_token_hash == hash(token))
    })
}

fn authorize_either(bridge: Option<&Bridge>, id: ConnectionId, token: &str) -> bool {
    authorize(bridge, id, token, true) || authorize(bridge, id, token, false)
}
async fn finish_pairing(
    id: Uuid,
    connections: &mut HashMap<ConnectionId, Connection>,
    slots: &mut HashMap<[u8; 32], Slot>,
    bridges: &mut HashMap<Uuid, Bridge>,
    frame: RendezvousServerFrame,
) {
    if let Some(b) = bridges.remove(&id) {
        if let Some(c) = connections.get_mut(&b.owner) {
            c.pairings = c.pairings.saturating_sub(1);
        }
        if let Some(c) = connections.get_mut(&b.joiner) {
            c.pairings = c.pairings.saturating_sub(1);
        }
        let _ = send(connections, b.owner, frame.clone()).await;
        let _ = send(connections, b.joiner, frame).await;
        if let Some(slot) = slots.remove(&b.slot_hash) {
            if let Some(c) = connections.get_mut(&slot.owner) {
                c.slots = c.slots.saturating_sub(1);
            }
        }
    }
}
async fn send(
    connections: &mut HashMap<ConnectionId, Connection>,
    id: ConnectionId,
    frame: RendezvousServerFrame,
) {
    if let Some(c) = connections.get(&id) {
        let _ = c.outbound.try_send(frame);
    }
}
async fn reject(
    connections: &mut HashMap<ConnectionId, Connection>,
    metrics: &MetricsState,
    id: ConnectionId,
    request_id: Option<Uuid>,
    code: &str,
) {
    metrics.0.write().await.rejected_frames += 1;
    send(
        connections,
        id,
        RendezvousServerFrame::Error {
            request_id,
            code: code.into(),
        },
    )
    .await;
}
async fn sync_metrics(
    c: &HashMap<ConnectionId, Connection>,
    s: &HashMap<[u8; 32], Slot>,
    b: &HashMap<Uuid, Bridge>,
    m: &MetricsState,
) {
    let mut x = m.0.write().await;
    x.active_connections = c.len();
    x.active_pairing_slots = s.len();
    x.active_pairing_bridges = b.len();
}
fn hash(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}
fn random_token() -> String {
    URL_SAFE_NO_PAD.encode(rng().random::<[u8; 32]>())
}
fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn generate_code() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz";
    let mut r = rng();
    (0..6)
        .map(|_| {
            (0..8)
                .map(|_| ALPHABET[r.random_range(0..ALPHABET.len())] as char)
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("-")
}

#[cfg(test)]
mod tests {
    use super::generate_code;

    #[test]
    fn pairing_code_is_six_words_and_manual_entry_safe() {
        let code = generate_code();
        let words: Vec<&str> = code.split('-').collect();
        assert_eq!(words.len(), 6);
        assert!(words.iter().all(|word| {
            (3..=12).contains(&word.len())
                && word.bytes().all(|byte| byte.is_ascii_lowercase())
        }));
    }
}
