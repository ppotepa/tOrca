use std::collections::HashMap;

use futures_util::SinkExt;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::mpsc,
    time::{Instant, timeout},
};
use tokio_tungstenite::{
    WebSocketStream, client_async,
    tungstenite::{Message, http::Request},
};
use torchat_client_runtime::PeerConnectionStatus;
use torchat_core::{
    Identity, PROTOCOL_VERSION,
    peer_protocol::{
        PEER_PATH, PeerAckKind, PeerClientHello, PeerClientProof, PeerFrame,
        PeerMessageEnvelope, handshake_transcript,
    },
    verify_signature,
};
use uuid::Uuid;

use super::{
    HANDSHAKE_TIMEOUT,
    queue::{ActiveDelivery, CommandQueues, EndpointProbe},
    types::{PeerDeliveryTag, PeerOutboundCommand, PeerSocket, PeerTransportEvent},
    wire::{connect_socket, random_nonce, recv_frame_with_timeout},
};

#[allow(clippy::too_many_arguments)]
pub(super) async fn send_outbound_command<S>(
    identity: &Identity,
    session_id: Uuid,
    command: PeerOutboundCommand,
    sink: &mut futures_util::stream::SplitSink<WebSocketStream<S>, Message>,
    active: &mut HashMap<Uuid, ActiveDelivery>,
    endpoint_probes: &mut HashMap<u64, EndpointProbe>,
    sent_endpoint_sequence: &mut u64,
    queues: &mut CommandQueues,
) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut latest_endpoint_sequence = None;
    for update in &command.endpoint_updates {
        if update.endpoint.sequence <= *sent_endpoint_sequence {
            continue;
        }
        sink.send(Message::Binary(
            torchat_core::peer_protocol::encode_frame(&PeerFrame::EndpointUpdate {
                update: update.clone(),
            })?
            .into(),
        ))
        .await
        .map_err(|error| format!("write peer endpoint update: {error}"))?;
        *sent_endpoint_sequence = update.endpoint.sequence;
        latest_endpoint_sequence = Some(update.endpoint.sequence);
    }

    if matches!(&command.delivery, PeerDeliveryTag::EndpointUpdate) {
        let nonce = command.sequence;
        sink.send(Message::Binary(
            torchat_core::peer_protocol::encode_frame(&PeerFrame::Ping { nonce })?.into(),
        ))
        .await
        .map_err(|error| format!("write peer endpoint probe: {error}"))?;
        endpoint_probes.insert(
            nonce,
            EndpointProbe {
                endpoint_sequence: latest_endpoint_sequence,
                sent_at: Instant::now(),
            },
        );
        return Ok(());
    }

    let envelope = PeerMessageEnvelope::new(
        identity,
        session_id,
        command.message_id,
        command.conversation_id,
        command.sequence,
        command.created_at,
        command.ciphertext,
    );
    let expected_ciphertext_hash = envelope.ciphertext_hash();
    sink.send(Message::Binary(
        torchat_core::peer_protocol::encode_frame(&PeerFrame::Message { envelope })?.into(),
    ))
    .await
    .map_err(|error| format!("write peer message: {error}"))?;

    if matches!(&command.delivery, PeerDeliveryTag::Ephemeral) {
        queues.complete(&command.delivery);
    } else {
        active.insert(
            command.message_id,
            ActiveDelivery {
                delivery: command.delivery,
                expected_ciphertext_hash,
                endpoint_sequence: latest_endpoint_sequence,
                sent_at: Instant::now(),
            },
        );
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn handle_outbound_frame<S>(
    frame: PeerFrame,
    installation_id: &str,
    session_id: Uuid,
    sink: &mut futures_util::stream::SplitSink<WebSocketStream<S>, Message>,
    active: &mut HashMap<Uuid, ActiveDelivery>,
    awaiting_delivered: &mut HashMap<Uuid, ActiveDelivery>,
    endpoint_probes: &mut HashMap<u64, EndpointProbe>,
    keepalive: &mut Option<(u64, Instant)>,
    queues: &mut CommandQueues,
    events: &mpsc::Sender<PeerTransportEvent>,
) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    match frame {
        PeerFrame::Ack { ack } => {
            if ack.session_id != session_id {
                return Ok(());
            }
            let message_id = ack.message_id;
            let Some(delivery) = active
                .get(&message_id)
                .or_else(|| awaiting_delivered.get(&message_id))
            else {
                return Ok(());
            };
            if ack.ciphertext_hash != delivery.expected_ciphertext_hash {
                return Err("peer acknowledgement ciphertext hash mismatch".to_owned());
            }
            let kind = ack.kind;
            let delivery_tag = delivery.delivery.clone();
            let endpoint_sequence = delivery.endpoint_sequence;
            let _ = events
                .send(PeerTransportEvent::Ack {
                    delivery: delivery_tag,
                    kind,
                    contact_installation_id: installation_id.to_owned(),
                    endpoint_sequence,
                })
                .await;

            match kind {
                PeerAckKind::Received => {}
                PeerAckKind::Persisted => {
                    if let Some(delivery) = active.remove(&message_id) {
                        if matches!(&delivery.delivery, PeerDeliveryTag::Message { .. }) {
                            awaiting_delivered.insert(message_id, delivery);
                        } else {
                            queues.complete(&delivery.delivery);
                        }
                    }
                }
                PeerAckKind::Delivered => {
                    if let Some(delivery) = active
                        .remove(&message_id)
                        .or_else(|| awaiting_delivered.remove(&message_id))
                    {
                        queues.complete(&delivery.delivery);
                    }
                }
            }
        }
        PeerFrame::Pong { nonce } => {
            if keepalive.is_some_and(|(expected, _)| expected == nonce) {
                *keepalive = None;
            }
            if let Some(probe) = endpoint_probes.remove(&nonce) {
                let _ = events
                    .send(PeerTransportEvent::Ack {
                        delivery: PeerDeliveryTag::EndpointUpdate,
                        kind: PeerAckKind::Persisted,
                        contact_installation_id: installation_id.to_owned(),
                        endpoint_sequence: probe.endpoint_sequence,
                    })
                    .await;
            }
        }
        PeerFrame::Ping { nonce } => {
            sink.send(Message::Binary(
                torchat_core::peer_protocol::encode_frame(&PeerFrame::Pong { nonce })?.into(),
            ))
            .await
            .map_err(|error| format!("write peer pong: {error}"))?;
        }
        PeerFrame::EndpointUpdate { .. } | PeerFrame::Message { .. } => {}
        _ => return Err("unexpected outbound peer frame".to_owned()),
    }
    Ok(())
}

pub(super) async fn connect_outbound(
    identity: &Identity,
    command: &PeerOutboundCommand,
    events: &mpsc::Sender<PeerTransportEvent>,
) -> Result<(WebSocketStream<PeerSocket>, Uuid), String> {
    let installation_id = command.endpoint.installation_id.clone();
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: installation_id.clone(),
            session_id: None,
            status: PeerConnectionStatus::Connecting,
            error: None,
            delivery: Some(command.delivery.clone()),
        })
        .await;
    let socket = connect_socket(
        &command.socks5_url,
        &command.endpoint.onion_address,
        command.endpoint.virtual_port,
    )
    .await?;
    let request = Request::builder()
        .method("GET")
        .uri(format!(
            "ws://{}:{}{}",
            command.endpoint.onion_address, command.endpoint.virtual_port, PEER_PATH
        ))
        .header("Host", command.endpoint.onion_address.as_str())
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header(
            "Sec-WebSocket-Key",
            tokio_tungstenite::tungstenite::handshake::client::generate_key(),
        )
        .body(())
        .map_err(|error| format!("build peer websocket request: {error}"))?;
    let (mut websocket, _) = timeout(HANDSHAKE_TIMEOUT, client_async(request, socket))
        .await
        .map_err(|_| "peer websocket handshake timed out".to_owned())?
        .map_err(|error| format!("connect peer websocket: {error}"))?;
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: installation_id.clone(),
            session_id: None,
            status: PeerConnectionStatus::Authenticating,
            error: None,
            delivery: Some(command.delivery.clone()),
        })
        .await;

    let nonce = random_nonce();
    let hello = PeerClientHello {
        protocol_version: PROTOCOL_VERSION,
        installation_id: identity.installation_id(),
        endpoint_sequence: command.local_endpoint.sequence,
        nonce,
    };
    super::wire::send_frame(
        &mut websocket,
        PeerFrame::ClientHello {
            hello: hello.clone(),
        },
    )
    .await?;
    let PeerFrame::ServerChallenge { challenge } = recv_frame_with_timeout(
        &mut websocket,
        false,
        HANDSHAKE_TIMEOUT,
        "peer server challenge",
    )
    .await?
    else {
        return Err("expected peer server challenge".into());
    };
    if challenge.installation_id != command.endpoint.installation_id
        || challenge.endpoint_sequence != command.endpoint.sequence
    {
        return Err("peer server identity or endpoint sequence mismatch".into());
    }
    let transcript = handshake_transcript(
        &hello,
        &challenge.installation_id,
        challenge.endpoint_sequence,
        &challenge.nonce,
        challenge.session_id,
        &command.endpoint.onion_address,
    );
    if !verify_signature(&command.peer_public_key, &transcript, &challenge.signature) {
        return Err("peer server challenge signature is invalid".into());
    }
    super::wire::send_frame(
        &mut websocket,
        PeerFrame::ClientProof {
            proof: PeerClientProof {
                session_id: challenge.session_id,
                signature: identity.sign(&transcript),
            },
        },
    )
    .await?;
    let PeerFrame::HandshakeAccepted { session_id } = recv_frame_with_timeout(
        &mut websocket,
        false,
        HANDSHAKE_TIMEOUT,
        "peer handshake acceptance",
    )
    .await?
    else {
        return Err("expected peer handshake acceptance".into());
    };
    if session_id != challenge.session_id {
        return Err("peer handshake session mismatch".into());
    }
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id,
            session_id: Some(session_id),
            status: PeerConnectionStatus::Connected,
            error: None,
            delivery: None,
        })
        .await;
    Ok((websocket, session_id))
}
