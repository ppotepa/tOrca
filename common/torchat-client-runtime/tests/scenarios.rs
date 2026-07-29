mod support;

use serde_json::{Map, Value, json};
use support::runtime_from_state;
use torchat_client_runtime::{MessageTransportOutcome, RuntimeRequest, RuntimeResponse, RuntimeTorStatus};

#[test]
fn shared_runtime_scenarios_pass() {
    let scenarios = scenario_file();
    assert_eq!(scenarios["protocol"].as_u64(), Some(1));
    for scenario in scenarios["scenarios"].as_array().expect("scenarios array") {
        run_scenario(scenario);
    }
}

fn scenario_file() -> Value {
    serde_json::from_str(include_str!("../../client-runtime-scenarios.json"))
        .expect("scenario file must parse")
}

fn run_scenario(scenario: &Value) {
    let id = scenario["id"].as_str().expect("scenario id");
    let initial = scenario.get("initialState").unwrap_or(&Value::Null);
    let mut runtime = runtime_from_state(initial);
    let mut responses = Vec::new();
    let mut events = Vec::new();

    for command in scenario["commands"].as_array().expect("commands array") {
        let method = command["method"]
            .as_str()
            .expect("command method")
            .to_owned();
        let params = resolve_placeholders(
            command.get("params").cloned().unwrap_or_else(|| json!({})),
            &responses,
        );
        responses.push(execute_command(&mut runtime, &method, params));
        events.extend(
            runtime
                .drain_events()
                .into_iter()
                .map(|event| serde_json::to_value(event).expect("event json")),
        );
    }

    if let Some(expected) = scenario.get("expectedResponses").and_then(Value::as_array) {
        assert_eq!(
            expected.len(),
            responses.len(),
            "scenario {id} response count"
        );
        for (index, expected_response) in expected.iter().enumerate() {
            assert_subset(
                expected_response,
                &responses[index],
                &format!("scenario {id} response {index}"),
            );
        }
    }

    if let Some(expected) = scenario.get("expectedEvents").and_then(Value::as_array) {
        assert_eq!(expected.len(), events.len(), "scenario {id} event count");
        for (index, expected_event) in expected.iter().enumerate() {
            assert_subset(
                expected_event,
                &events[index],
                &format!("scenario {id} event {index}"),
            );
        }
    }

    if let Some(expected_final) = scenario.get("expectedFinalState") {
        let storage = runtime.storage();
        if let Some(expected_messages) = expected_final.get("messages").and_then(Value::as_array) {
            let actual = storage.messages.clone();
            assert_collection_subset(id, "messages", expected_messages, &actual);
        }
        if let Some(expected_conversations) = expected_final
            .get("conversations")
            .and_then(Value::as_array)
        {
            let actual = storage.conversations.clone();
            assert_collection_subset(id, "conversations", expected_conversations, &actual);
        }
        if let Some(expected_inbox) = expected_final.get("pairingInbox").and_then(Value::as_array) {
            let actual = storage.inbox.clone();
            assert_collection_subset(id, "pairingInbox", expected_inbox, &actual);
        }
        if let Some(expected_outbox) = expected_final
            .get("pairingOutbox")
            .and_then(Value::as_array)
        {
            let actual = storage.outbox.clone();
            assert_collection_subset(id, "pairingOutbox", expected_outbox, &actual);
        }
    }
}

fn execute_command(runtime: &mut support::ScenarioRuntime, method: &str, params: Value) -> Value {
    let response = match method {
        "runtimeBootstrap" => RuntimeResponse::ok(None, runtime.bootstrap_runtime().expect("bootstrap"))
            .expect("response"),
        "runtimeReportTorStatus" => {
            let status: RuntimeTorStatus =
                serde_json::from_value(params["status"].clone()).expect("status");
            runtime.report_tor_status(status);
            RuntimeResponse::ok(None, true).expect("response")
        }
        "runtimeApplyTransportOutcome" => {
            let message_id = params["messageId"].as_str().expect("messageId");
            let outcome: MessageTransportOutcome =
                serde_json::from_value(params["outcome"].clone()).expect("outcome");
            match runtime.apply_message_transport_outcome(
                uuid::Uuid::parse_str(message_id).expect("valid messageId"),
                outcome,
            ) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeFlushPendingSendEffects" => {
            match runtime.prepare_pending_send_effects() {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeAcceptPairingPreview" => {
            match runtime.prepare_accept_pairing(params["pairingId"].as_str().expect("pairingId")) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeAcceptPairingCommit" => {
            match runtime.commit_accept_pairing(
                params["pairingId"].as_str().expect("pairingId"),
                params["offerInviteId"].as_str().expect("offerInviteId").to_owned(),
                params["offerPayload"].as_str().expect("offerPayload").to_owned(),
            ) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeRejectPairingPreview" => {
            match runtime.prepare_reject_pairing(params["pairingId"].as_str().expect("pairingId")) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeRejectPairingCommit" => {
            match runtime.commit_reject_pairing(params["pairingId"].as_str().expect("pairingId")) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeCancelPairingPreview" => {
            match runtime.prepare_cancel_pairing(params["pairingId"].as_str().expect("pairingId")) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeCancelPairingCommit" => {
            match runtime.confirm_pairing_cancelled(params["pairingId"].as_str().expect("pairingId")) {
                Ok(()) => RuntimeResponse::ok(None, true).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeWelcomeAccepted" => {
            let contact = serde_json::from_value(params["contact"].clone()).expect("contact");
            let open_conversation = params
                .get("openConversation")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let invite_id = params
                .get("inviteId")
                .and_then(Value::as_str)
                .map(str::to_owned);
            match runtime.welcome_accepted(contact, open_conversation, invite_id) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeApplyPairingPeerOutcome" => {
            let pairing_id = params["pairingId"].as_str().expect("pairingId");
            let outcome = serde_json::from_value(params["outcome"].clone()).expect("outcome");
            match runtime.apply_pairing_peer_outcome(pairing_id, outcome) {
                Ok(()) => RuntimeResponse::ok(None, true).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        "runtimeReceiveMessage" => {
            let conversation_id = params["id"].as_str().expect("id");
            let text = params["text"].as_str().expect("text").to_owned();
            let message_id = params
                .get("messageId")
                .and_then(Value::as_str)
                .map(|value| uuid::Uuid::parse_str(value).expect("valid messageId"));
            match runtime.receive_message(conversation_id, text, message_id) {
                Ok(result) => RuntimeResponse::ok(None, result).expect("response"),
                Err(error) => RuntimeResponse::error(None, error),
            }
        }
        _ => runtime.dispatch_request(RuntimeRequest {
            id: None,
            method: method.to_owned(),
            params,
        }),
    };
    serde_json::to_value(response).expect("response json")
}

fn resolve_placeholders(value: Value, responses: &[Value]) -> Value {
    match value {
        Value::String(text) if text.starts_with("$response[") => {
            lookup_response_placeholder(&text, responses)
        }
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| resolve_placeholders(item, responses))
                .collect(),
        ),
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| (key, resolve_placeholders(value, responses)))
                .collect::<Map<_, _>>(),
        ),
        other => other,
    }
}

fn lookup_response_placeholder(path: &str, responses: &[Value]) -> Value {
    let (index, rest) = path
        .strip_prefix("$response[")
        .and_then(|value| value.split_once(']'))
        .expect("valid response placeholder");
    let mut value = responses[index.parse::<usize>().expect("response index")].clone();
    for segment in rest.trim_start_matches('.').split('.') {
        if segment.is_empty() {
            continue;
        }
        value = value
            .get(segment)
            .unwrap_or_else(|| panic!("placeholder segment {segment} missing in {path}"))
            .clone();
    }
    value
}

fn assert_collection_subset<T: serde::Serialize>(
    scenario: &str,
    key: &str,
    expected: &[Value],
    actual: &[T],
) {
    let actual_json = actual
        .iter()
        .map(|item| serde_json::to_value(item).expect("item json"))
        .collect::<Vec<_>>();
    for expected_item in expected {
        assert!(
            actual_json
                .iter()
                .any(|actual_item| is_subset(expected_item, actual_item)),
            "scenario {scenario} final {key} missing subset {expected_item}; actual {actual_json:?}"
        );
    }
}

fn assert_subset(expected: &Value, actual: &Value, context: &str) {
    assert!(
        is_subset(expected, actual),
        "{context} expected subset {expected}, actual {actual}"
    );
}

fn is_subset(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Object(expected_object), Value::Object(actual_object)) => {
            expected_object.iter().all(|(key, expected_value)| {
                actual_object
                    .get(key)
                    .is_some_and(|actual_value| is_subset(expected_value, actual_value))
            })
        }
        (Value::Array(expected_items), Value::Array(actual_items)) => {
            expected_items.len() == actual_items.len()
                && expected_items
                    .iter()
                    .zip(actual_items)
                    .all(|(expected_item, actual_item)| is_subset(expected_item, actual_item))
        }
        _ => expected == actual,
    }
}
