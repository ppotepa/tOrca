use std::{collections::HashMap, sync::Arc};

use futures_util::{SinkExt, StreamExt};
use tokio::{
    net::TcpListener,
    sync::{Semaphore, mpsc},
    time::{Instant, timeout},
};
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};
use torchat_core::{
    Identity,
    peer_protocol::{PeerEndpointBundle, PeerFrame},
};
use torchat_runtime::PeerConnectionStatus;
use uuid::Uuid;

use crate::PeerError;

use super::{
    ACK_TIMEOUT, EVENT_CAPACITY, KEEPALIVE_INTERVAL, KEEPALIVE_TIMEOUT, MAX_IN_FLIGHT,
    OUTBOUND_CAPACITY, SESSION_CAPACITY, SESSION_IDLE_TIMEOUT, SESSION_TICK,
    inbound::serve_inbound,
    outbound::{connect_outbound, handle_outbound_frame, send_outbound_command},
    queue::{ActiveDelivery, CommandQueues, EndpointProbe},
    types::{
        AuthorizedPeer, PeerDeliveryTag, PeerOutboundCommand, PeerSessionLease, PeerSocket,
        PeerTransportEvent, SharedPeerState,
    },
    wire::{close_sink, decode_message, random_u64, same_peer_endpoint},
};

#[derive(Clone)]
pub struct PeerTransportHandle {
    local_port: u16,
    state: Arc<SharedPeerState>,
    identity_private_key: [u8; 32],
    outbound: mpsc::Sender<PeerOutboundCommand>,
}

impl PeerTransportHandle {
    pub async fn bind(
        identity_private_key: [u8; 32],
    ) -> Result<(Self, mpsc::Receiver<PeerTransportEvent>), PeerError> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|error| PeerError::Transport(format!("bind peer listener: {error}")))?;
        let local_port = listener
            .local_addr()
            .map_err(|error| PeerError::Transport(format!("read peer listener port: {error}")))?
            .port();
        let state = Arc::new(SharedPeerState::default());
        let (event_tx, event_rx) = mpsc::channel(EVENT_CAPACITY);
        let (outbound_tx, mut outbound_rx) =
            mpsc::channel::<PeerOutboundCommand>(OUTBOUND_CAPACITY);

        let ingress_state = state.clone();
        let ingress_events = event_tx.clone();
        let ingress_limit = Arc::new(Semaphore::new(32));
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let Ok(permit) = ingress_limit.clone().try_acquire_owned() else {
                    drop(stream);
                    continue;
                };
                let state = ingress_state.clone();
                let events = ingress_events.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) =
                        serve_inbound(stream, identity_private_key, state, events.clone()).await
                    {
                        let _ = events
                            .send(PeerTransportEvent::IngressError { error })
                            .await;
                    }
                });
            }
        });

        tokio::spawn(async move {
            let mut sessions = HashMap::<String, mpsc::Sender<PeerOutboundCommand>>::new();
            while let Some(command) = outbound_rx.recv().await {
                let installation_id = command.endpoint.installation_id.clone();
                if let Some(sender) = sessions.get(&installation_id).cloned()
                    && sender.send(command.clone()).await.is_ok()
                {
                    continue;
                }

                sessions.remove(&installation_id);
                let (session_tx, session_rx) = mpsc::channel(SESSION_CAPACITY);
                if session_tx.send(command).await.is_err() {
                    continue;
                }
                sessions.insert(installation_id.clone(), session_tx);
                let events = event_tx.clone();
                tokio::spawn(async move {
                    run_contact_session(identity_private_key, installation_id, session_rx, events)
                        .await;
                });
            }
        });

        Ok((
            Self {
                local_port,
                state,
                identity_private_key,
                outbound: outbound_tx,
            },
            event_rx,
        ))
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    pub fn set_local_endpoint(&self, endpoint: PeerEndpointBundle) {
        if let Ok(mut value) = self.state.local_endpoint.write() {
            *value = Some(endpoint);
        }
    }

    pub fn authorize_contact(
        &self,
        endpoint: &PeerEndpointBundle,
        local_endpoint: PeerEndpointBundle,
        inbound_capability_id: String,
        capability_secret: Vec<u8>,
    ) {
        if let Ok(mut authorized) = self.state.authorized.write() {
            authorized.insert(
                endpoint.installation_id.clone(),
                AuthorizedPeer {
                    public_key: endpoint.identity_public_key.clone(),
                    endpoint: endpoint.clone(),
                    local_endpoint,
                    inbound_capability_id,
                    capability_secret,
                },
            );
        }
    }

    pub async fn send(&self, command: PeerOutboundCommand) -> Result<(), PeerError> {
        self.outbound
            .send(command)
            .await
            .map_err(|_| PeerError::Transport("peer outbound queue is closed".to_owned()))
    }

    pub fn try_send(&self, command: PeerOutboundCommand) -> Result<(), PeerError> {
        self.outbound.try_send(command).map_err(|error| {
            PeerError::Transport(format!("peer outbound queue is unavailable: {error}"))
        })
    }

    pub fn identity_private_key(&self) -> [u8; 32] {
        self.identity_private_key
    }
}

async fn run_contact_session(
    identity_private_key: [u8; 32],
    installation_id: String,
    mut commands: mpsc::Receiver<PeerOutboundCommand>,
    events: mpsc::Sender<PeerTransportEvent>,
) {
    let identity = Identity::from_private_key_bytes(identity_private_key);
    let mut queues = CommandQueues::default();
    let mut channel_open = true;

    loop {
        while let Ok(command) = commands.try_recv() {
            queues.enqueue(command);
        }
        while !queues.has_dial_worthy() {
            if !channel_open {
                return;
            }
            match timeout(SESSION_IDLE_TIMEOUT, commands.recv()).await {
                Ok(Some(command)) => queues.enqueue(command),
                Ok(None) | Err(_) => return,
            }
            queues.drop_ephemeral_without_session();
        }

        let Some(template) = queues.connection_template().cloned() else {
            continue;
        };
        match connect_outbound(&identity, &template, &events).await {
            Ok((websocket, session_id)) => {
                let result = run_connected_session(
                    &identity,
                    &installation_id,
                    websocket,
                    session_id,
                    &mut commands,
                    &mut queues,
                    &events,
                    &mut channel_open,
                )
                .await;
                if let Err(error) = result {
                    fail_queued_commands(&installation_id, &mut queues, &events, &error).await;
                }
            }
            Err(error) => {
                fail_queued_commands(&installation_id, &mut queues, &events, &error).await;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_connected_session(
    identity: &Identity,
    installation_id: &str,
    websocket: WebSocketStream<PeerSocket>,
    session_id: Uuid,
    commands: &mut mpsc::Receiver<PeerOutboundCommand>,
    queues: &mut CommandQueues,
    events: &mpsc::Sender<PeerTransportEvent>,
    channel_open: &mut bool,
) -> Result<(), String> {
    let connected_endpoint = queues
        .connection_template()
        .map(|command| command.endpoint.clone())
        .ok_or_else(|| "peer session has no connection template".to_owned())?;
    let _session_lease = PeerSessionLease {
        events: events.clone(),
        installation_id: installation_id.to_owned(),
        session_id,
    };
    let (mut sink, mut stream) = websocket.split();
    let mut active = HashMap::<Uuid, ActiveDelivery>::new();
    let mut awaiting_delivered = HashMap::<Uuid, ActiveDelivery>::new();
    let mut endpoint_probes = HashMap::<u64, EndpointProbe>::new();
    let mut sent_endpoint_sequence = 0_u64;
    let mut last_activity = Instant::now();
    let mut next_keepalive = Instant::now() + KEEPALIVE_INTERVAL;
    let mut keepalive = None::<(u64, Instant)>;

    loop {
        while let Ok(command) = commands.try_recv() {
            queues.enqueue(command);
        }

        while active.len() < MAX_IN_FLIGHT {
            let Some(command) = queues.pop_next(true) else {
                break;
            };
            if !same_peer_endpoint(&connected_endpoint, &command.endpoint) {
                queues.push_front(command);
                if active.is_empty() {
                    complete_persisted_waiters(&mut awaiting_delivered, queues);
                    close_sink(&mut sink).await;
                    return Ok(());
                }
                break;
            }
            let failed_delivery = command.delivery.clone();
            if let Err(error) = send_outbound_command(
                identity,
                session_id,
                command,
                &mut sink,
                &mut active,
                &mut endpoint_probes,
                &mut sent_endpoint_sequence,
                queues,
            )
            .await
            {
                queues.complete(&failed_delivery);
                if failed_delivery.is_durable() {
                    fail_delivery(installation_id, failed_delivery, events, error.clone()).await;
                }
                fail_active_deliveries(
                    installation_id,
                    &mut active,
                    &mut awaiting_delivered,
                    queues,
                    events,
                    &error,
                )
                .await;
                close_sink(&mut sink).await;
                return Err(error);
            }
            last_activity = Instant::now();
        }

        let now = Instant::now();
        expire_persisted_waiters(now, &mut awaiting_delivered, queues);
        if let Some((_, deadline)) = keepalive
            && now >= deadline
        {
            let error = "peer keepalive timed out".to_owned();
            fail_active_deliveries(
                installation_id,
                &mut active,
                &mut awaiting_delivered,
                queues,
                events,
                &error,
            )
            .await;
            close_sink(&mut sink).await;
            return Err(error);
        }
        if active
            .values()
            .any(|delivery| now.duration_since(delivery.sent_at) >= ACK_TIMEOUT)
            || endpoint_probes
                .values()
                .any(|probe| now.duration_since(probe.sent_at) >= ACK_TIMEOUT)
        {
            let error = "peer acknowledgement timed out".to_owned();
            fail_active_deliveries(
                installation_id,
                &mut active,
                &mut awaiting_delivered,
                queues,
                events,
                &error,
            )
            .await;
            close_sink(&mut sink).await;
            return Err(error);
        }

        if now >= next_keepalive {
            let nonce = random_u64();
            let write_result =
                match torchat_core::peer_protocol::encode_frame(&PeerFrame::Ping { nonce }) {
                    Ok(frame) => sink
                        .send(Message::Binary(frame.into()))
                        .await
                        .map_err(|error| format!("write peer websocket keepalive: {error}")),
                    Err(error) => Err(error),
                };
            if let Err(error) = write_result {
                fail_active_deliveries(
                    installation_id,
                    &mut active,
                    &mut awaiting_delivered,
                    queues,
                    events,
                    &error,
                )
                .await;
                close_sink(&mut sink).await;
                return Err(error);
            }
            keepalive = Some((nonce, Instant::now() + KEEPALIVE_TIMEOUT));
            next_keepalive = Instant::now() + KEEPALIVE_INTERVAL;
        }

        if queues.is_empty()
            && active.is_empty()
            && awaiting_delivered.is_empty()
            && endpoint_probes.is_empty()
            && now.duration_since(last_activity) >= SESSION_IDLE_TIMEOUT
        {
            close_sink(&mut sink).await;
            return Ok(());
        }
        if !*channel_open
            && queues.is_empty()
            && active.is_empty()
            && awaiting_delivered.is_empty()
            && endpoint_probes.is_empty()
        {
            close_sink(&mut sink).await;
            return Ok(());
        }

        tokio::select! {
            command = commands.recv(), if *channel_open => {
                match command {
                    Some(command) => queues.enqueue(command),
                    None => *channel_open = false,
                }
            }
            message = stream.next() => {
                let message = match message {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => {
                        let error = format!("read peer websocket: {error}");
                        fail_active_deliveries(
                            installation_id,
                            &mut active,
                            &mut awaiting_delivered,
                            queues,
                            events,
                            &error,
                        ).await;
                        return Err(error);
                    }
                    None => {
                        let error = "peer websocket closed".to_owned();
                        fail_active_deliveries(
                            installation_id,
                            &mut active,
                            &mut awaiting_delivered,
                            queues,
                            events,
                            &error,
                        ).await;
                        return Err(error);
                    }
                };
                let frame = match decode_message(message, true) {
                    Ok(Some(frame)) => frame,
                    Ok(None) => {
                        let error = "peer websocket closed".to_owned();
                        fail_active_deliveries(
                            installation_id,
                            &mut active,
                            &mut awaiting_delivered,
                            queues,
                            events,
                            &error,
                        ).await;
                        return Err(error);
                    }
                    Err(error) => {
                        fail_active_deliveries(
                            installation_id,
                            &mut active,
                            &mut awaiting_delivered,
                            queues,
                            events,
                            &error,
                        ).await;
                        return Err(error);
                    }
                };
                last_activity = Instant::now();
                if let Err(error) = handle_outbound_frame(
                    frame,
                    installation_id,
                    session_id,
                    &mut sink,
                    &mut active,
                    &mut awaiting_delivered,
                    &mut endpoint_probes,
                    &mut keepalive,
                    queues,
                    events,
                ).await {
                    fail_active_deliveries(
                        installation_id,
                        &mut active,
                        &mut awaiting_delivered,
                        queues,
                        events,
                        &error,
                    ).await;
                    close_sink(&mut sink).await;
                    return Err(error);
                }
            }
            _ = tokio::time::sleep(SESSION_TICK) => {}
        }
    }
}

fn expire_persisted_waiters(
    now: Instant,
    awaiting_delivered: &mut HashMap<Uuid, ActiveDelivery>,
    queues: &mut CommandQueues,
) {
    let expired = awaiting_delivered
        .iter()
        .filter_map(|(message_id, delivery)| {
            (now.duration_since(delivery.sent_at) >= ACK_TIMEOUT).then_some(*message_id)
        })
        .collect::<Vec<_>>();
    for message_id in expired {
        if let Some(delivery) = awaiting_delivered.remove(&message_id) {
            queues.complete(&delivery.delivery);
        }
    }
}

fn complete_persisted_waiters(
    awaiting_delivered: &mut HashMap<Uuid, ActiveDelivery>,
    queues: &mut CommandQueues,
) {
    for (_, delivery) in awaiting_delivered.drain() {
        queues.complete(&delivery.delivery);
    }
}

async fn fail_active_deliveries(
    installation_id: &str,
    active: &mut HashMap<Uuid, ActiveDelivery>,
    awaiting_delivered: &mut HashMap<Uuid, ActiveDelivery>,
    queues: &mut CommandQueues,
    events: &mpsc::Sender<PeerTransportEvent>,
    error: &str,
) {
    for (_, delivery) in active.drain() {
        queues.complete(&delivery.delivery);
        fail_delivery(installation_id, delivery.delivery, events, error.to_owned()).await;
    }
    // PERSISTED is the durability boundary. Losing the socket while awaiting
    // DELIVERED must never schedule the same ciphertext for another delivery.
    complete_persisted_waiters(awaiting_delivered, queues);
}

async fn fail_queued_commands(
    installation_id: &str,
    queues: &mut CommandQueues,
    events: &mpsc::Sender<PeerTransportEvent>,
    error: &str,
) {
    for command in queues.drain_failed() {
        if command.delivery.is_durable() {
            fail_delivery(installation_id, command.delivery, events, error.to_owned()).await;
        }
    }
}

async fn fail_delivery(
    installation_id: &str,
    delivery: PeerDeliveryTag,
    events: &mpsc::Sender<PeerTransportEvent>,
    error: String,
) {
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: installation_id.to_owned(),
            session_id: None,
            status: PeerConnectionStatus::Backoff,
            error: Some(error),
            delivery: Some(delivery),
        })
        .await;
}
