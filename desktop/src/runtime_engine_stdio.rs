use anyhow::{Context, Result, bail};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::io::{BufRead, Write};
use torchat_client_engine::{
    ClientEngine, EngineCommand, EngineConfig, EngineEvent, PlatformFact, PlatformKind, TorPhase,
    event::{ResponsePayload, ResponseResult},
};
use torchat_client_engine::config::SecretBytes;
use torchat_client_runtime::{RuntimeEvent, RuntimeRequest, RuntimeResponse};

use crate::{cli::Cli, identity_store, tor_runtime::TorRuntime};

fn write_json_line(value: impl Serialize) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, &value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn write_runtime_response(response: RuntimeResponse) -> Result<()> {
    write_json_line(response)
}

fn write_runtime_event(event: RuntimeEvent) -> Result<()> {
    write_json_line(serde_json::to_value(event)?)
}

pub(crate) fn platform_kind() -> PlatformKind {
    #[cfg(target_os = "windows")]
    {
        return PlatformKind::Windows;
    }
    #[cfg(target_os = "linux")]
    {
        return PlatformKind::Linux;
    }
    #[cfg(target_os = "macos")]
    {
        return PlatformKind::Macos;
    }
    #[allow(unreachable_code)]
    PlatformKind::Linux
}

pub(crate) fn database_key(identity: &torchat_core::Identity) -> Vec<u8> {
    let mut hash = Sha256::new();
    hash.update(b"torchat-desktop-local-store-v1");
    hash.update(identity.private_key_bytes());
    hash.finalize().to_vec()
}

pub(crate) fn relay_url(cli: &Cli) -> Result<reqwest::Url> {
    let value = cli
        .server_url
        .clone()
        .context("desktop engine stdio requires --server-url")?;
    value.parse().context("parse --server-url")
}

pub(crate) fn start_tor(
    cli: &Cli,
) -> Result<(TorRuntime, std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>)> {
    if let Some(binary) = &cli.tor_binary {
        let data_dir = cli
            .tor_data_dir
            .clone()
            .context("--tor-data-dir is required with --tor-binary for stdio-engine")?;
        return TorRuntime::start(binary, &data_dir);
    }
    if let Some(proxy) = &cli.socks5_proxy {
        return Ok(TorRuntime::external(proxy.clone()));
    }
    bail!("desktop engine stdio requires either --tor-binary or --socks5-proxy")
}

pub fn run_stdio_engine(cli: Cli) -> Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async move {
        let identity = identity_store::load_or_create(cli.identity_file.as_deref())?;
        let database_path = identity_store::state_path(cli.identity_file.as_deref())?;
        let log_directory = database_path.parent().map(|parent| parent.join("engine-logs"));
        let (tor_runtime, status_rx) = start_tor(&cli)?;
        let socks_url: reqwest::Url = tor_runtime.socks_url().parse().context("parse SOCKS5 URL")?;
        let config = EngineConfig {
            database_path,
            database_key: SecretBytes(database_key(&identity)),
            identity_private_key: SecretBytes(identity.private_key_bytes().to_vec()),
            relay_onion_url: relay_url(&cli)?,
            initial_socks5_url: Some(socks_url),
            log_directory,
            platform: platform_kind(),
        };
        let mut engine = ClientEngine::new(config)?;
        engine.start().await?;
        engine
            .submit_platform_fact(
                "desktop-tor-endpoint",
                PlatformFact::TorEndpointAvailable {
                    socks5_url: tor_runtime.socks_url().to_owned(),
                },
            )
            .await?;

        let (request_tx, request_rx) = std::sync::mpsc::channel::<String>();
        std::thread::spawn(move || {
            let stdin = std::io::stdin();
            for line in stdin.lock().lines().map_while(Result::ok) {
                if request_tx.send(line).is_err() {
                    break;
                }
            }
        });

        let mut tor_status_seq = 0_u64;
        loop {
            drain_tor_statuses(&engine, &status_rx, &mut tor_status_seq).await?;
            pump_unsolicited_events(&mut engine).await?;

            let line = match request_rx.recv_timeout(std::time::Duration::from_millis(50)) {
                Ok(value) => value,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let request: RuntimeRequest = match serde_json::from_str(&line) {
                Ok(value) => value,
                Err(error) => {
                    write_runtime_response(RuntimeResponse::error(None, error))?;
                    continue;
                }
            };
            let id = request.id.clone();
            let command = match map_runtime_request(&request) {
                Ok(value) => value,
                Err(error) => {
                    write_runtime_response(RuntimeResponse::error(id, error))?;
                    continue;
                }
            };
            let shutdown = matches!(command, EngineCommand::Shutdown);
            let request_id = request.id.unwrap_or_else(|| "desktop-stdio".to_owned());
            engine.submit(request_id.clone(), command).await?;
            let response = wait_for_response(&mut engine, &status_rx, &mut tor_status_seq, &request_id).await?;
            write_runtime_response(response_to_runtime_response(id, response)?)?;
            if shutdown {
                break;
            }
        }
        Ok(())
    })
}

pub(crate) async fn drain_tor_statuses(
    engine: &ClientEngine,
    status_rx: &std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
    tor_status_seq: &mut u64,
) -> Result<()> {
    while let Ok(status) = status_rx.try_recv() {
        *tor_status_seq = tor_status_seq.saturating_add(1);
        engine
            .submit_platform_fact(
                format!("desktop-tor-status-{tor_status_seq}"),
                PlatformFact::TorStatus {
                    phase: map_tor_phase(&status.phase),
                    progress: status.progress.clamp(0, 100) as u8,
                    detail: if status.detail.is_empty() {
                        status.label
                    } else {
                        status.detail
                    },
                },
            )
            .await?;
    }
    Ok(())
}

async fn pump_unsolicited_events(engine: &mut ClientEngine) -> Result<()> {
    while let Some(event) = engine.poll_timeout(std::time::Duration::from_millis(5)).await {
        if let Some(runtime_event) = map_engine_event_to_runtime_event(event)? {
            write_runtime_event(runtime_event)?;
        }
    }
    Ok(())
}

pub(crate) async fn wait_for_response(
    engine: &mut ClientEngine,
    status_rx: &std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
    tor_status_seq: &mut u64,
    request_id: &str,
) -> Result<ResponseResult> {
    loop {
        drain_tor_statuses(engine, status_rx, tor_status_seq).await?;
        let Some(event) = engine.poll_timeout(std::time::Duration::from_millis(50)).await else {
            continue;
        };
        match event {
            EngineEvent::Response { request_id: value, result } if value == request_id => return Ok(result),
            other => {
                if let Some(runtime_event) = map_engine_event_to_runtime_event(other)? {
                    write_runtime_event(runtime_event)?;
                }
            }
        }
    }
}

fn map_engine_event_to_runtime_event(event: EngineEvent) -> Result<Option<RuntimeEvent>> {
    Ok(match event {
        EngineEvent::Runtime(event) => Some(event),
        EngineEvent::Log(log) => Some(RuntimeEvent::RuntimeLog {
            message: if log.level.is_empty() {
                log.message
            } else {
                format!("[{}] {}", log.level, log.message)
            },
        }),
        EngineEvent::Fatal(error) => Some(RuntimeEvent::RuntimeError {
            message: format!("{}: {}", error.code, error.message),
        }),
        EngineEvent::NotificationRequested(notification) => Some(RuntimeEvent::RuntimeLog {
            message: format!(
                "notification_requested:{}:{}",
                notification.id, notification.title
            ),
        }),
        EngineEvent::Connection(_) | EngineEvent::Response { .. } => None,
    })
}

fn response_to_runtime_response(
    id: Option<String>,
    response: ResponseResult,
) -> Result<RuntimeResponse> {
    match response {
        ResponseResult::Ok { payload } => {
            let value = match payload {
                ResponsePayload::Empty => serde_json::Value::Bool(true),
                ResponsePayload::Json { value } => value,
            };
            Ok(RuntimeResponse::ok(id, value)?)
        }
        ResponseResult::Error { message, .. } => Ok(RuntimeResponse::error(id, message)),
    }
}

fn map_runtime_request(request: &RuntimeRequest) -> Result<EngineCommand> {
    let text = |name: &str| {
        request
            .params
            .get(name)
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    Ok(match request.method.as_str() {
        "bootstrap" => EngineCommand::Bootstrap,
        "connect" => EngineCommand::Connect,
        "getIdentity" => EngineCommand::GetIdentity,
        "getProfile" => EngineCommand::GetProfile,
        "setNickname" => EngineCommand::SetNickname {
            nickname: text("nickname"),
        },
        "refreshPairingCode" => EngineCommand::RefreshPairingCode,
        "submitPairingCode" => EngineCommand::SubmitPairingCode { code: text("code") },
        "pairingInbox" => EngineCommand::PairingInbox,
        "pairingOutbox" => EngineCommand::PairingOutbox,
        "acceptPairing" => EngineCommand::AcceptPairing {
            pairing_id: text("pairingId"),
        },
        "rejectPairing" => EngineCommand::RejectPairing {
            pairing_id: text("pairingId"),
        },
        "cancelPairing" => EngineCommand::CancelPairing {
            pairing_id: text("pairingId"),
        },
        "archivePairing" => EngineCommand::ArchivePairing {
            pairing_id: text("pairingId"),
        },
        "verifyContact" => EngineCommand::VerifyContact {
            installation_id: text("installationId"),
        },
        "listContacts" => EngineCommand::ListContacts,
        "listConversations" => EngineCommand::ListConversations,
        "listMessages" => EngineCommand::ListMessages {
            conversation_id: text("id"),
        },
        "startConversation" => EngineCommand::StartConversation {
            contact_id: text("contactId"),
        },
        "openConversation" => EngineCommand::OpenConversation { conversation_id: text("id") },
        "closeConversation" => EngineCommand::CloseConversation,
        "sendMessage" => EngineCommand::SendMessage {
            conversation_id: text("id"),
            body: text("text"),
        },
        "shutdown" => EngineCommand::Shutdown,
        other => bail!("engine stdio does not support runtime method: {other}"),
    })
}

fn map_tor_phase(value: &str) -> TorPhase {
    match value {
        "ready" | "external" => TorPhase::Ready,
        "bootstrapping" => TorPhase::Bootstrapping,
        "warning" | "failed" => TorPhase::Failed,
        _ => TorPhase::Starting,
    }
}
