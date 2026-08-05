use torchat_runtime::{
    MessageSendEffect, PairingSendEffect, PairingSendKind, RuntimeSendEffect,
};

#[test]
fn runtime_send_effect_serializes_like_existing_transport_payloads() {
    let message = RuntimeSendEffect::from(MessageSendEffect {
        message_id: "message-1".to_owned(),
        conversation_id: "conversation-1".to_owned(),
        recipient_installation_id: "installation-bob".to_owned(),
        body: "hello".to_owned(),
        reply_to: None,
    });
    let pairing = RuntimeSendEffect::from(PairingSendEffect {
        pairing_id: "pairing-1".to_owned(),
        recipient_installation_id: "installation-bob".to_owned(),
        kind: PairingSendKind::Offer,
        payload: Some("payload".to_owned()),
    });

    let message_json = serde_json::to_value(&message).expect("message send effect serializes");
    let pairing_json = serde_json::to_value(&pairing).expect("pairing send effect serializes");

    assert_eq!(message_json["messageId"], "message-1");
    assert_eq!(message_json["conversationId"], "conversation-1");
    assert_eq!(message_json["recipientInstallationId"], "installation-bob");
    assert_eq!(message_json["body"], "hello");

    assert_eq!(pairing_json["pairingId"], "pairing-1");
    assert_eq!(pairing_json["recipientInstallationId"], "installation-bob");
    assert_eq!(pairing_json["kind"], "OFFER");
    assert_eq!(pairing_json["payload"], "payload");
}

#[test]
fn runtime_send_effect_round_trips_from_message_and_pairing_payloads() {
    let message = serde_json::json!({
        "messageId": "message-1",
        "conversationId": "conversation-1",
        "recipientInstallationId": "installation-bob",
        "body": "hello"
    });
    let pairing = serde_json::json!({
        "pairingId": "pairing-1",
        "recipientInstallationId": "installation-bob",
        "kind": "REJECTION",
        "payload": null
    });

    let message_effect: RuntimeSendEffect =
        serde_json::from_value(message).expect("message effect parses");
    let pairing_effect: RuntimeSendEffect =
        serde_json::from_value(pairing).expect("pairing effect parses");

    assert_eq!(
        message_effect.recipient_installation_id(),
        "installation-bob"
    );
    assert_eq!(
        pairing_effect.recipient_installation_id(),
        "installation-bob"
    );
}
