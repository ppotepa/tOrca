use super::*;

fn onion(fill: char) -> String {
    format!("{}.onion", fill.to_string().repeat(56))
}

#[test]
fn signed_endpoint_rejects_tampering_and_stale_update() {
    let identity = Identity::generate();
    let endpoint = PeerEndpointBundle::new(&identity, onion('a'), 1, 10, None);
    endpoint.validate(11).unwrap();
    let mut tampered = endpoint.clone();
    tampered.onion_address = onion('b');
    assert!(tampered.validate(11).is_err());
    let successor = PeerEndpointBundle::new(&identity, onion('b'), 2, 12, None);
    successor.validate_successor(&endpoint, 12).unwrap();
    assert!(endpoint.validate_successor(&successor, 12).is_err());
}

#[test]
fn signed_endpoint_rejects_excessive_future_clock_skew() {
    let identity = Identity::generate();
    let endpoint = PeerEndpointBundle::new(
        &identity,
        onion('a'),
        1,
        10,
        Some(10 + MAX_ENDPOINT_CLOCK_SKEW_SECS + 1),
    );
    assert_eq!(
        endpoint.validate(10).unwrap_err(),
        "peer endpoint expiry exceeds clock skew bound"
    );
}

#[test]
fn endpoint_issued_at_accepts_ten_minutes_and_rejects_twenty_four_hours() {
    let identity = Identity::generate();
    let one_minute = PeerEndpointBundle::new(&identity, onion('a'), 1, 70, None);
    assert!(one_minute.validate(10).is_ok());
    let ten_minutes = PeerEndpointBundle::new(
        &identity,
        onion('a'),
        2,
        10 + MAX_ENDPOINT_CLOCK_SKEW_SECS,
        None,
    );
    assert!(ten_minutes.validate(10).is_ok());
    let day = PeerEndpointBundle::new(&identity, onion('a'), 3, 10 + 24 * 60 * 60, None);
    assert_eq!(
        day.validate(10).unwrap_err(),
        "peer endpoint issued-at exceeds clock skew bound"
    );
}

#[test]
fn handshake_transcript_binds_onion_and_both_identities() {
    let client = Identity::generate();
    let server = Identity::generate();
    let hello = PeerClientHello {
        protocol_version: PROTOCOL_VERSION,
        installation_id: client.installation_id(),
        endpoint_sequence: 1,
        capability_id: String::new(),
        capability_proof: String::new(),
        nonce: [7; 32],
    };
    let session_id = Uuid::new_v4();
    let first = handshake_transcript(
        &hello,
        &server.installation_id(),
        2,
        &[9; 32],
        session_id,
        &onion('a'),
    );
    let second = handshake_transcript(
        &hello,
        &server.installation_id(),
        2,
        &[9; 32],
        session_id,
        &onion('b'),
    );
    assert_ne!(first, second);
    let signature = server.sign(&first);
    assert!(verify_signature(&server.public_key(), &first, &signature));
    assert!(!verify_signature(&server.public_key(), &second, &signature));
}

#[test]
fn capability_proof_binds_hello_and_secret() {
    let identity = Identity::generate();
    let mut hello = PeerClientHello {
        protocol_version: PROTOCOL_VERSION,
        installation_id: identity.installation_id(),
        endpoint_sequence: 1,
        capability_id: "1234567890abcdef".to_owned(),
        capability_proof: String::new(),
        nonce: [4; 32],
    };
    hello.capability_proof = capability_proof(b"secret", &hello);
    assert!(verify_capability_proof(b"secret", &hello));
    assert!(!verify_capability_proof(b"wrong-secret", &hello));
    hello.nonce[0] ^= 1;
    assert!(!verify_capability_proof(b"secret", &hello));
}

#[test]
fn signed_message_reuses_ciphertext_and_detects_changes() {
    let identity = Identity::generate();
    let envelope = PeerMessageEnvelope::new(
        &identity,
        Uuid::new_v4(),
        Uuid::new_v4(),
        "conversation",
        1,
        42,
        b"ciphertext".to_vec(),
    );
    envelope
        .verify(&identity.installation_id(), &identity.public_key())
        .unwrap();
    let mut changed = envelope.clone();
    changed.ciphertext.push(1);
    assert!(
        changed
            .verify(&identity.installation_id(), &identity.public_key())
            .is_err()
    );
}

#[test]
fn attachment_sized_ciphertext_stays_within_peer_frame_limit() {
    let identity = Identity::generate();
    let envelope = PeerMessageEnvelope::new(
        &identity,
        Uuid::new_v4(),
        Uuid::new_v4(),
        "conversation",
        1,
        42,
        vec![7; 96 * 1024],
    );
    let encoded = encode_frame(&PeerFrame::Message { envelope }).unwrap();
    assert!(encoded.len() < MAX_PEER_FRAME_BYTES);
    assert!(decode_frame(&encoded, true).is_ok());
}

#[test]
fn preauth_frame_limit_is_stricter() {
    let frame = PeerFrame::ProtocolError {
        code: "x".repeat(MAX_PREAUTH_FRAME_BYTES),
    };
    let encoded = encode_frame(&frame).unwrap();
    assert!(decode_frame(&encoded, false).is_err());
    assert!(decode_frame(&encoded, true).is_ok());
}

#[test]
fn rejected_ack_round_trips_with_message_identity() {
    let ack = PeerAck {
        session_id: Uuid::new_v4(),
        message_id: Uuid::new_v4(),
        kind: PeerAckKind::Rejected,
        ciphertext_hash: [7; 32],
    };
    let encoded = encode_frame(&PeerFrame::Ack { ack: ack.clone() }).unwrap();
    let decoded = decode_frame(&encoded, true).unwrap();
    assert_eq!(decoded, PeerFrame::Ack { ack });
}

#[test]
fn peer_frame_decoder_rejects_bounded_malformed_corpus_without_panic() {
    let mut seed = 0x8765_4321_u32;
    for length in 0..=512_usize {
        let mut bytes = vec![0_u8; length];
        for byte in &mut bytes {
            seed = seed.rotate_left(7) ^ 0xa5a5_5a5a;
            *byte = seed as u8;
        }
        let _ = decode_frame(&bytes, true);
    }
}
