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
        PEER_PATH, PeerAck, PeerAckKind, PeerEndpointBundle, PeerFrame, PeerPresenceState,
        PeerServerChallenge, handshake_transcript,
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
    let (websocket, peer_id, peer_key, mut peer_endpoint, session_id) =
        authenticate_inbound(websocket, &identity, &state).await?;
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: peer_id.clone(),
            session_id: Some(session_id),
            status: torchat_runtime::PeerConnectionStatus::Connected,
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
                    let previous_authorization = authorized.get(&peer_id).cloned();
                    authorized.insert(
                        peer_id.clone(),
                        AuthorizedPeer {
                            public_key: peer_key.clone(),
                            endpoint: peer_endpoint.clone(),
                            local_endpoint: previous_authorization
                                .as_ref()
                                .map(|value| value.local_endpoint.clone())
                                .ok_or_else(|| "peer authorization disappeared".to_owned())?,
                            inbound_capability_id: previous_authorization
                                .as_ref()
                                .map(|value| value.inbound_capability_id.clone())
                                .unwrap_or_default(),
                            capability_secret: previous_authorization
                                .map(|value| value.capability_secret)
                                .unwrap_or_default(),
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
            PeerFrame::Presence {
                state, expires_at, ..
            } => {
                events
                    .send(PeerTransportEvent::PresenceChanged {
                        installation_id: peer_id.clone(),
                        online: !matches!(state, PeerPresenceState::Offline)
                            && expires_at >= unix_secs() * 1000,
                        idle: matches!(state, PeerPresenceState::Away),
                        observed_at: unix_secs() * 1000,
                        expires_at,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
            }
            PeerFrame::Typing {
                typing, expires_at, ..
            } => {
                events
                    .send(PeerTransportEvent::TypingChanged {
                        installation_id: peer_id.clone(),
                        typing: typing && expires_at >= unix_secs() * 1000,
                        expires_at,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
            }
            PeerFrame::ConversationFocus {
                focused,
                expires_at,
                ..
            } => {
                events
                    .send(PeerTransportEvent::ConversationFocusChanged {
                        installation_id: peer_id.clone(),
                        focused: focused && expires_at >= unix_secs() * 1000,
                        expires_at,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
            }
            PeerFrame::ProbeRequest { nonce } => {
                writer_tx
                    .send(PeerFrame::ProbeResponse {
                        nonce,
                        presence: PeerPresenceState::Online,
                        observed_at: unix_secs() * 1000,
                    })
                    .await
                    .map_err(|_| "peer websocket writer stopped".to_owned())?;
            }
            PeerFrame::ProbeResponse { presence, .. } => {
                events
                    .send(PeerTransportEvent::PresenceChanged {
                        installation_id: peer_id.clone(),
                        online: !matches!(presence, PeerPresenceState::Offline),
                        idle: matches!(presence, PeerPresenceState::Away),
                        observed_at: unix_secs() * 1000,
                        expires_at: unix_secs() * 1000 + 45_000,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
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
    let local_endpoint = &authorized.local_endpoint;
    if hello.endpoint_sequence < authorized.endpoint.sequence {
        return Err("peer endpoint sequence is stale".into());
    }
    if hello.capability_id.is_empty() || hello.capability_id != authorized.inbound_capability_id {
        return Err("peer capability is not authorized".into());
    }
    if authorized.capability_secret.is_empty()
        || !torchat_core::peer_protocol::verify_capability_proof(
            &authorized.capability_secret,
            &hello,
        )
    {
        return Err("peer capability proof is invalid".into());
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use futures_util::{SinkExt, StreamExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::{
        client_async,
        tungstenite::{Message, http::Request},
    };
    use torchat_core::peer_protocol::{
        PeerClientHello, PeerClientProof, PeerEndpointBundle, PeerFrame, capability_proof,
        decode_frame, encode_frame, handshake_transcript,
    };

    use super::*;
    use crate::peer::types::{AuthorizedPeer, SharedPeerState};

    fn endpoint(
        identity: &Identity,
        sequence: u64,
        capability: Option<&str>,
    ) -> PeerEndpointBundle {
        let mut capabilities = vec!["peer_message_v1".to_owned()];
        if let Some(capability) = capability {
            capabilities.push(format!("contact_endpoint_v1:{capability}"));
        }
        let mut endpoint = PeerEndpointBundle {
            protocol_version: PROTOCOL_VERSION,
            installation_id: identity.installation_id(),
            onion_address: format!("{}.onion", "a".repeat(56)),
            virtual_port: 443,
            identity_public_key: identity.public_key(),
            capabilities,
            sequence,
            issued_at: 1,
            expires_at: None,
            signature: String::new(),
        };
        endpoint.signature = identity.sign(&endpoint.signing_bytes());
        endpoint
    }

    #[tokio::test]
    async fn challenge_uses_the_per_contact_endpoint_advertised_to_the_peer() {
        let server_identity = Identity::generate();
        let client_identity = Identity::generate();
        let capability_id = "1234567890abcdef";
        let capability_secret = b"per-contact-secret-material".to_vec();
        let client_endpoint = endpoint(&client_identity, 7, None);
        let base_server_endpoint = endpoint(&server_identity, 1, None);
        let contact_server_endpoint = endpoint(&server_identity, 2, Some(capability_id));

        let state = Arc::new(SharedPeerState::default());
        *state.local_endpoint.write().unwrap() = Some(base_server_endpoint);
        state.authorized.write().unwrap().insert(
            client_identity.installation_id(),
            AuthorizedPeer {
                public_key: client_identity.public_key(),
                endpoint: client_endpoint.clone(),
                local_endpoint: contact_server_endpoint.clone(),
                inbound_capability_id: capability_id.to_owned(),
                capability_secret: capability_secret.clone(),
            },
        );

        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let (event_tx, mut event_rx) = mpsc::channel(8);
        let server_state = state.clone();
        let server_key = server_identity.private_key_bytes();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            serve_inbound(stream, server_key, server_state, event_tx).await
        });

        let stream = TcpStream::connect(address).await.unwrap();
        let request = Request::builder()
            .method("GET")
            .uri(format!("ws://{address}{PEER_PATH}"))
            .header("Host", address.to_string())
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header(
                "Sec-WebSocket-Key",
                tokio_tungstenite::tungstenite::handshake::client::generate_key(),
            )
            .body(())
            .unwrap();
        let (mut websocket, _) = client_async(request, stream).await.unwrap();

        let mut hello = PeerClientHello {
            protocol_version: PROTOCOL_VERSION,
            installation_id: client_identity.installation_id(),
            endpoint_sequence: client_endpoint.sequence,
            capability_id: capability_id.to_owned(),
            capability_proof: String::new(),
            nonce: random_nonce(),
        };
        hello.capability_proof = capability_proof(&capability_secret, &hello);
        websocket
            .send(Message::Binary(
                encode_frame(&PeerFrame::ClientHello {
                    hello: hello.clone(),
                })
                .unwrap()
                .into(),
            ))
            .await
            .unwrap();

        let challenge =
            match decode_frame(&websocket.next().await.unwrap().unwrap().into_data(), false)
                .unwrap()
            {
                PeerFrame::ServerChallenge { challenge } => challenge,
                frame => panic!("unexpected frame: {frame:?}"),
            };
        assert_eq!(
            challenge.endpoint_sequence,
            contact_server_endpoint.sequence
        );
        let transcript = handshake_transcript(
            &hello,
            &challenge.installation_id,
            challenge.endpoint_sequence,
            &challenge.nonce,
            challenge.session_id,
            &contact_server_endpoint.onion_address,
        );
        websocket
            .send(Message::Binary(
                encode_frame(&PeerFrame::ClientProof {
                    proof: PeerClientProof {
                        session_id: challenge.session_id,
                        signature: client_identity.sign(&transcript),
                    },
                })
                .unwrap()
                .into(),
            ))
            .await
            .unwrap();
        let accepted =
            decode_frame(&websocket.next().await.unwrap().unwrap().into_data(), false).unwrap();
        assert!(matches!(accepted, PeerFrame::HandshakeAccepted { .. }));
        assert!(matches!(
            event_rx.recv().await,
            Some(PeerTransportEvent::ConnectionChanged {
                status: torchat_runtime::PeerConnectionStatus::Connected,
                ..
            })
        ));

        websocket.close(None).await.unwrap();
        assert!(server.await.unwrap().is_ok());
    }
}
