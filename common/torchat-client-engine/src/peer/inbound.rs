use futures_util::{SinkExt, StreamExt};
use tokio::{
    net::TcpStream,
    sync::mpsc,
    time::{Duration, timeout},
};
use tokio_tungstenite::{
    WebSocketStream, accept_hdr_async,
    tungstenite::{
        Message,
        handshake::server::{Request as ServerRequest, Response as ServerResponse},
    },
};
use torchat_core::{
    Identity, PROTOCOL_VERSION,
    peer_protocol::{
        PEER_PATH, PeerAck, PeerAckKind, PeerEndpointBundle, PeerFrame, PeerServerChallenge,
        handshake_transcript,
    },
    verify_signature,
};
use uuid::Uuid;

use super::{
    ACK_TIMEOUT, EVENT_CAPACITY, HANDSHAKE_TIMEOUT,
    types::{AuthorizedPeer, PeerSessionLease, PeerTransportEvent, SharedState},
    wire::{decode_message, random_nonce, recv_frame_with_timeout, send_frame, unix_secs},
};

#[allow(clippy::result_large_err)] // tungstenite fixes this callback error type.
pub(super) async fn serve_inbound(
    stream: TcpStream,
    identity_private_key: [u8; 32],
    state: SharedState,
    events: mpsc::Sender<PeerTransportEvent>,
) -> Result<(), String> {
    let websocket = timeout(
        HANDSHAKE_TIMEOUT,
        accept_hdr_async(
            stream,
            |request: &ServerRequest, response: ServerResponse| {
                if request.uri().path() != PEER_PATH {
                    return Err(
                        tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(
                            Some("not found".to_owned()),
                        ),
                    );
                }
                Ok(response)
            },
        ),
    )
    .await
    .map_err(|_| "peer websocket handshake timed out".to_owned())?
    .map_err(|error| format!("accept peer websocket: {error}"))?;
    let identity = Identity::from_private_key_bytes(identity_private_key);
    let local_endpoint = state
        .local_endpoint
        .read()
        .map_err(|_| "peer endpoint lock poisoned".to_owned())?
        .clone()
        .ok_or_else(|| "local onion endpoint is unavailable".to_owned())?;

    let (websocket, peer_id, peer_key, mut peer_endpoint, session_id) =
        authenticate_inbound(websocket, &identity, &local_endpoint, &state).await?;
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: peer_id.clone(),
            session_id: Some(session_id),
            status: torchat_client_runtime::PeerConnectionStatus::Connected,
            error: None,
            delivery: None,
        })
        .await;
    let _session_lease = PeerSessionLease {
        events: events.clone(),
        installation_id: peer_id.clone(),
        session_id,
    };

    // The socket reader must never wait for storage or application processing.
    // ACKs are forwarded by a dedicated writer task, allowing one authenticated
    // onion session to carry many messages concurrently.
    let (mut sink, mut stream) = websocket.split();
    let (writer_tx, mut writer_rx) = mpsc::channel::<PeerFrame>(EVENT_CAPACITY);
    let writer = tokio::spawn(async move {
        while let Some(frame) = writer_rx.recv().await {
            sink.send(Message::Binary(
                torchat_core::peer_protocol::encode_frame(&frame)?.into(),
            ))
            .await
            .map_err(|error| format!("write peer websocket: {error}"))?;
        }
        let _ = timeout(Duration::from_secs(5), sink.close()).await;
        Ok::<(), String>(())
    });

    while let Some(message) = stream.next().await {
        let message = message.map_err(|error| format!("read peer frame: {error}"))?;
        let Some(frame) = decode_message(message, true)? else {
            break;
        };
        match frame {
            PeerFrame::Message { envelope } => {
                if envelope.session_id != session_id {
                    return Err("peer message session mismatch".into());
                }
                envelope.verify(&peer_id, &peer_key)?;
                let received = PeerAck {
                    session_id,
                    message_id: envelope.message_id,
                    kind: PeerAckKind::Received,
                    ciphertext_hash: envelope.ciphertext_hash(),
                };
                writer_tx
                    .send(PeerFrame::Ack { ack: received })
                    .await
                    .map_err(|_| "peer websocket writer stopped".to_owned())?;

                let (persisted_tx, persisted_rx) = tokio::sync::oneshot::channel();
                let (delivered_tx, delivered_rx) = tokio::sync::oneshot::channel();
                events
                    .send(PeerTransportEvent::InboundMessage {
                        envelope,
                        persisted: persisted_tx,
                        delivered: delivered_tx,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
                spawn_ack_forwarder(writer_tx.clone(), persisted_rx, delivered_rx);
            }
            PeerFrame::EndpointUpdate { update } => {
                if update.endpoint.installation_id != peer_id
                    || update.endpoint.identity_public_key != peer_key
                {
                    return Err("peer endpoint update changed authenticated identity".into());
                }
                // Reconnects may replay an update that the receiver persisted
                // before its acknowledgement reached the sender.
                if update.endpoint.sequence <= peer_endpoint.sequence {
                    continue;
                }
                update.validate(&peer_endpoint, unix_secs())?;
                peer_endpoint = update.endpoint.clone();
                if let Ok(mut authorized) = state.authorized.write() {
                    authorized.insert(
                        peer_id.clone(),
                        AuthorizedPeer {
                            public_key: peer_key.clone(),
                            endpoint: peer_endpoint.clone(),
                        },
                    );
                }
                events
                    .send(PeerTransportEvent::EndpointUpdated {
                        endpoint: peer_endpoint.clone(),
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
            }
            PeerFrame::Ping { nonce } => {
                writer_tx
                    .send(PeerFrame::Pong { nonce })
                    .await
                    .map_err(|_| "peer websocket writer stopped".to_owned())?;
            }
            PeerFrame::Pong { .. } | PeerFrame::Ack { .. } => {}
            _ => return Err("unexpected authenticated peer frame".into()),
        }
    }

    drop(writer_tx);
    let _ = writer.await;
    Ok(())
}

fn spawn_ack_forwarder(
    writer: mpsc::Sender<PeerFrame>,
    persisted_rx: tokio::sync::oneshot::Receiver<Result<PeerAck, String>>,
    delivered_rx: tokio::sync::oneshot::Receiver<Result<PeerAck, String>>,
) {
    tokio::spawn(async move {
        let Ok(Ok(Ok(persisted))) = timeout(ACK_TIMEOUT, persisted_rx).await else {
            return;
        };
        if writer
            .send(PeerFrame::Ack { ack: persisted })
            .await
            .is_err()
        {
            return;
        }
        if let Ok(Ok(Ok(delivered))) = timeout(ACK_TIMEOUT, delivered_rx).await {
            let _ = writer.send(PeerFrame::Ack { ack: delivered }).await;
        }
    });
}

async fn authenticate_inbound(
    mut websocket: WebSocketStream<TcpStream>,
    identity: &Identity,
    local_endpoint: &PeerEndpointBundle,
    state: &super::types::SharedPeerState,
) -> Result<
    (
        WebSocketStream<TcpStream>,
        String,
        String,
        PeerEndpointBundle,
        Uuid,
    ),
    String,
> {
    let frame = recv_frame_with_timeout(
        &mut websocket,
        false,
        HANDSHAKE_TIMEOUT,
        "peer client hello",
    )
    .await?;
    let PeerFrame::ClientHello { hello } = frame else {
        return Err("expected peer client hello".into());
    };
    if hello.protocol_version != PROTOCOL_VERSION {
        return Err("unsupported peer protocol".into());
    }
    let authorized = state
        .authorized
        .read()
        .map_err(|_| "authorized peer lock poisoned".to_owned())?
        .get(&hello.installation_id)
        .cloned()
        .ok_or_else(|| "peer is not an authorized contact".to_owned())?;
    if hello.endpoint_sequence < authorized.endpoint.sequence {
        return Err("peer endpoint sequence is stale".into());
    }

    let server_nonce = random_nonce();
    let session_id = Uuid::new_v4();
    let transcript = handshake_transcript(
        &hello,
        &identity.installation_id(),
        local_endpoint.sequence,
        &server_nonce,
        session_id,
        &local_endpoint.onion_address,
    );
    let challenge = PeerServerChallenge {
        protocol_version: PROTOCOL_VERSION,
        installation_id: identity.installation_id(),
        endpoint_sequence: local_endpoint.sequence,
        nonce: server_nonce,
        session_id,
        signature: identity.sign(&transcript),
    };
    send_frame(&mut websocket, PeerFrame::ServerChallenge { challenge }).await?;
    let PeerFrame::ClientProof { proof } = recv_frame_with_timeout(
        &mut websocket,
        false,
        HANDSHAKE_TIMEOUT,
        "peer client proof",
    )
    .await?
    else {
        return Err("expected peer client proof".into());
    };
    if proof.session_id != session_id
        || !verify_signature(&authorized.public_key, &transcript, &proof.signature)
    {
        return Err("peer client proof is invalid".into());
    }
    send_frame(&mut websocket, PeerFrame::HandshakeAccepted { session_id }).await?;
    Ok((
        websocket,
        hello.installation_id,
        authorized.public_key,
        authorized.endpoint,
        session_id,
    ))
}
