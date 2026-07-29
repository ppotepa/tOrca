use anyhow::Result;
use serde::Serialize;
use std::io::{BufRead, Write};
use torchat_client_runtime::{RuntimeEvent, RuntimeRequest, RuntimeResponse};
use uuid::Uuid;

use crate::{
    DesktopState,
    runtime_support::{
        accept_pairing, bail_on_relay_command_error, reject_pairing, wait_for_pairing_code,
        wait_for_pairing_request, wait_for_relay,
    },
};

fn write_runtime(value: impl Serialize) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, &value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn local_runtime(
    state: &mut DesktopState,
    method: &str,
    params: serde_json::Value,
) -> Result<(serde_json::Value, Vec<RuntimeEvent>)> {
    crate::runtime_adapter::dispatch_local_runtime_command_with_events(state, method, params)
}

fn dispatch_local(
    state: &mut DesktopState,
    command_events: &mut Vec<RuntimeEvent>,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let (value, events) = local_runtime(state, method, params)?;
    *command_events = events;
    Ok(value)
}

fn is_local_runtime_stdio_method(method: &str) -> bool {
    matches!(
        method,
        "identity"
            | "profile"
            | "prepareSubmitPairingCode"
            | "pairingInbox"
            | "mergePairingInbox"
            | "pairingOutbox"
            | "mergePairingOutbox"
            | "prepareAcceptPairing"
            | "commitAcceptPairing"
            | "prepareRejectPairing"
            | "commitRejectPairing"
            | "prepareCancelPairing"
            | "confirmPairingCancelled"
            | "preparePendingSendEffects"
            | "applyPairingPeerOutcome"
            | "welcomeAccepted"
            | "bootstrapRuntime"
            | "reportTorStatus"
            | "applyRemoteProfile"
            | "reportRuntimeError"
            | "reportRuntimeLog"
            | "bootstrapContact"
            | "archivePairing"
            | "verifyContact"
            | "setNickname"
            | "contacts"
            | "conversations"
            | "messages"
            | "receiveMessage"
            | "applyMessageTransportOutcome"
    )
}

pub fn run_stdio_runtime(cli: crate::cli::Cli) -> Result<()> {
    let mut state = DesktopState::new(cli)?;
    let (_, events) = local_runtime(&mut state, "bootstrapRuntime", serde_json::json!({}))?;
    state.enqueue_runtime_events(events);
    let (request_tx, request_rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines().map_while(Result::ok) {
            if request_tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut last_status = String::new();
    let mut last_connected = false;
    let mut last_error = String::new();
    loop {
        state.tick();
        let status_key = format!(
            "{:?}:{:?}:{:?}:{:?}",
            state.tor_status.phase,
            state.tor_status.label,
            state.tor_status.progress,
            state.tor_status.latency_ms
        );
        if status_key != last_status {
            let status = state.tor_status.clone();
            let (_, events) = local_runtime(
                &mut state,
                "reportTorStatus",
                serde_json::json!({"status": status}),
            )?;
            state.enqueue_runtime_events(events);
            last_status = status_key;
        }
        if state.connected && !last_connected {
            let profile = serde_json::json!({
                "installationId": state.identity.installation_id(),
                "nickname": state.nickname.clone(),
                "publicKey": state.identity.public_key(),
                "fingerprint": state.identity.fingerprint(),
            });
            let (_, events) = local_runtime(
                &mut state,
                "applyRemoteProfile",
                serde_json::json!({"profile": profile}),
            )?;
            state.enqueue_runtime_events(events);
        }
        last_connected = state.connected;
        if state.error != last_error {
            if !state.error.is_empty() {
                let message = state.error.clone();
                let (_, events) = local_runtime(
                    &mut state,
                    "reportRuntimeError",
                    serde_json::json!({"message": message}),
                )?;
                state.enqueue_runtime_events(events);
            }
            last_error = state.error.clone();
        }
        for event in state.drain_runtime_events() {
            write_runtime(serde_json::to_value(event)?)?;
        }
        let line = match request_rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(value) => value,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        let request: RuntimeRequest = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                write_runtime(RuntimeResponse::error(None, error))?;
                continue;
            }
        };
        let id = request.id.clone();
        let method = request.method.clone();
        let params = request.params;
        let mut command_events = Vec::new();
        let result: Result<serde_json::Value> = (|| {
            let text = |name: &str| {
                params
                    .get(name)
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
            };
            match method.as_str() {
                value if is_local_runtime_stdio_method(value) => {
                    dispatch_local(&mut state, &mut command_events, value, params.clone())
                }
                "connect" => {
                    wait_for_relay(&mut state, std::time::Duration::from_secs(180))?;
                    Ok(serde_json::json!(true))
                }
                "refreshPairingCode" => {
                    let code =
                        wait_for_pairing_code(&mut state, std::time::Duration::from_secs(30))?;
                    Ok(serde_json::to_value(code)?)
                }
                "submitPairingCode" => {
                    let prepared = dispatch_local(
                        &mut state,
                        &mut command_events,
                        "prepareSubmitPairingCode",
                        serde_json::json!({"code": text("code")}),
                    )?;
                    let value = wait_for_pairing_request(
                        &mut state,
                        prepared.as_str().unwrap_or_else(|| text("code")).to_owned(),
                        std::time::Duration::from_secs(30),
                    )?;
                    Ok(serde_json::to_value(value)?)
                }
                "cancelPairing" => {
                    if !state.connected {
                        wait_for_relay(&mut state, std::time::Duration::from_secs(90))?;
                    }
                    let value = dispatch_local(
                        &mut state,
                        &mut command_events,
                        "prepareCancelPairing",
                        serde_json::json!({"pairingId": text("pairingId")}),
                    )?;
                    let pairing_id = Uuid::parse_str(
                        value
                            .get("pairingId")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_else(|| text("pairingId")),
                    )?;
                    state
                        .relay_commands
                        .try_send(crate::transport::RelayCommand::CancelPairing(pairing_id))
                        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
                    state.error.clear();
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
                    while std::time::Instant::now() < deadline {
                        state.tick();
                        bail_on_relay_command_error(&state)?;
                        if !state
                            .pairing_outbox
                            .iter()
                            .any(|item| item.pairing_id == pairing_id)
                        {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(50));
                    }
                    let _ = dispatch_local(
                        &mut state,
                        &mut command_events,
                        "confirmPairingCancelled",
                        serde_json::json!({"pairingId": pairing_id.to_string()}),
                    )?;
                    Ok(serde_json::json!(true))
                }
                "acceptPairing" => {
                    accept_pairing(&mut state, Uuid::parse_str(text("pairingId"))?)?;
                    Ok(serde_json::json!(true))
                }
                "rejectPairing" => {
                    reject_pairing(&mut state, Uuid::parse_str(text("pairingId"))?)?;
                    Ok(serde_json::json!(true))
                }
                "openConversation" => {
                    command_events = crate::runtime_adapter::open_conversation_with_runtime(
                        &mut state,
                        text("id"),
                    )?;
                    state.open_selected_peer_view(text("id"))?;
                    Ok(serde_json::json!(true))
                }
                "closeConversation" => {
                    let _ = dispatch_local(
                        &mut state,
                        &mut command_events,
                        "closeConversation",
                        serde_json::json!({}),
                    )?;
                    state.clear_selected_peer_view();
                    Ok(serde_json::json!(true))
                }
                "startConversation" => {
                    let peer = text("contactId");
                    let _ = dispatch_local(
                        &mut state,
                        &mut command_events,
                        "startConversation",
                        serde_json::json!({"contactId": peer}),
                    )?;
                    if state.conversations.contains_key(peer) {
                        state.select_peer(peer)?;
                    }
                    Ok(serde_json::json!(state.conversations.contains_key(peer)))
                }
                "sendMessage" => {
                    state.select_peer(text("id"))?;
                    state.send(text("text"))?;
                    Ok(serde_json::json!(true))
                }
                "shutdown" => Ok(serde_json::json!("shutdown")),
                method => anyhow::bail!("unknown runtime method: {method}"),
            }
        })();
        match result {
            Ok(value) => {
                write_runtime(RuntimeResponse::ok(id, value)?)?;
                for event in command_events {
                    write_runtime(serde_json::to_value(event)?)?;
                }
                if method == "shutdown" {
                    break;
                }
            }
            Err(error) => write_runtime(RuntimeResponse::error(id, format!("{error:#}")))?,
        }
    }
    Ok(())
}
