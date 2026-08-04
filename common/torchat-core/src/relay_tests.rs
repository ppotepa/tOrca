use super::*;

#[test]
fn signed_welcome_round_trip_rejects_tampering() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let payload = RelayPayloadV1::welcome(
        &alice,
        "Alice",
        bob.installation_id(),
        "invite".into(),
        b"welcome",
        b"tree",
    );
    let decoded = RelayPayloadV1::decode(&payload.encode().unwrap()).unwrap();
    decoded
        .verify_welcome(&alice.installation_id(), &bob.installation_id())
        .unwrap();
    let RelayPayloadV1::Welcome {
        mut sender,
        recipient,
        invite_id,
        welcome,
        ratchet_tree,
        peer_endpoint,
        peer_capability_id,
        peer_capability_secret,
        signature,
        version,
    } = decoded
    else {
        unreachable!()
    };
    sender.nickname = "Mallory".into();
    let changed = RelayPayloadV1::Welcome {
        version,
        sender,
        recipient,
        invite_id,
        welcome,
        ratchet_tree,
        peer_endpoint,
        peer_capability_id,
        peer_capability_secret,
        signature,
    };
    assert!(
        changed
            .verify_welcome(&alice.installation_id(), &bob.installation_id())
            .is_err()
    );
}

#[test]
fn signed_welcome_applied_round_trip_rejects_wrong_sender() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let payload =
        RelayPayloadV1::welcome_applied(&alice, "Alice", bob.installation_id(), "invite-1".into());
    let decoded = RelayPayloadV1::decode(&payload.encode().unwrap()).unwrap();
    assert_eq!(
        decoded
            .verify_welcome_applied(&alice.installation_id(), &bob.installation_id())
            .unwrap(),
        "invite-1"
    );
    assert!(
        decoded
            .verify_welcome_applied(&bob.installation_id(), &bob.installation_id())
            .is_err()
    );
}

#[test]
fn signed_relationship_removal_applied_round_trip_rejects_wrong_recipient() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let payload = RelayPayloadV1::relationship_removal_applied(
        &alice,
        bob.installation_id(),
        "removal-1".into(),
        7,
        1234,
    );
    let decoded = RelayPayloadV1::decode(&payload.encode().unwrap()).unwrap();
    assert_eq!(
        decoded
            .verify_relationship_removal_applied(&alice.installation_id(), &bob.installation_id())
            .unwrap(),
        "removal-1"
    );
    assert!(
        decoded
            .verify_relationship_removal_applied(
                &alice.installation_id(),
                &Identity::generate().installation_id()
            )
            .is_err()
    );
}

#[test]
fn relay_decoder_rejects_bounded_malformed_corpus_without_panic() {
    use base64::Engine;
    let mut seed = 0x0bad_cafe_u32;
    for length in 0..=512_usize {
        let mut bytes = vec![0_u8; length];
        for byte in &mut bytes {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            *byte = (seed >> 16) as u8;
        }
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
        let _ = RelayPayloadV1::decode(&encoded);
    }
}
