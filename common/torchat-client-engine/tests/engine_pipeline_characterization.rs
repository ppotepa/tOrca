use torchat_client_engine::{
    ConnectionSnapshot, ConnectionState, EngineCommand, EngineCommandEnvelope, EngineEvent,
    PlatformFact,
    event::{ResponsePayload, ResponseResult},
};

#[test]
fn send_message_command_round_trips_without_losing_correlation_fields() {
    let envelope = EngineCommandEnvelope {
        request_id: "request-1".to_owned(),
        command_id: None,
        command: EngineCommand::SendMessage {
            conversation_id: "conversation-1".to_owned(),
            body: "hello".to_owned(),
            reply_to_message_id: Some("message-0".to_owned()),
        },
    };

    let encoded = serde_json::to_string(&envelope).expect("command serializes");
    let decoded: EngineCommandEnvelope =
        serde_json::from_str(&encoded).expect("command deserializes");

    assert_eq!(decoded, envelope);
}

#[test]
fn response_event_keeps_request_id_and_payload_shape() {
    let event = EngineEvent::Response {
        request_id: "request-2".to_owned(),
        result: ResponseResult::Ok {
            payload: ResponsePayload::Json {
                value: serde_json::json!({"accepted": true}),
            },
        },
    };

    let value = serde_json::to_value(&event).expect("event serializes");

    assert_eq!(value["type"], "response");
    assert_eq!(value["requestId"], "request-2");
    assert_eq!(value["result"]["status"], "ok");
    assert_eq!(value["result"]["payload"]["value"]["accepted"], true);
}

#[test]
fn connection_backoff_snapshot_round_trips_generation_and_deadline() {
    let snapshot = ConnectionSnapshot {
        state: ConnectionState::Backoff {
            attempt: 4,
            retry_in_ms: 12_000,
        },
        generation: 9,
        detail: "relay unavailable".to_owned(),
    };

    let encoded = serde_json::to_string(&snapshot).expect("snapshot serializes");
    let decoded: ConnectionSnapshot =
        serde_json::from_str(&encoded).expect("snapshot deserializes");

    assert_eq!(decoded, snapshot);
}

#[test]
fn platform_facts_remain_transport_agnostic_inputs() {
    let facts = [
        PlatformFact::NetworkChanged { online: false },
        PlatformFact::AppVisibilityChanged { foreground: false },
        PlatformFact::BackgroundExecutionRestricted { restricted: true },
    ];

    for fact in facts {
        let encoded = serde_json::to_string(&fact).expect("fact serializes");
        let decoded: PlatformFact = serde_json::from_str(&encoded).expect("fact deserializes");
        assert_eq!(decoded, fact);
    }
}
