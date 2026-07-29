use anyhow::{Context, Result, bail};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::io::{BufRead, Write};
use torchat_client_engine::{
    ClientEngine, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineEvent,
    EngineFatalError, PlatformFact, PlatformKind, config::SecretBytes,
};
use url::Url;

use crate::{cli::Cli, identity_store, tor_runtime::TorRuntime};

fn write_json_line(value: impl Serialize) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, &value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
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
    hash.update(b"torchat-client-engine-database-key-v1");
    hash.update(identity.private_key_bytes());
    hash.finalize().to_vec()
}

pub(crate) fn relay_url(cli: &Cli) -> Result<Url> {
    let value = cli
        .server_url
        .clone()
        .or_else(|| option_env!("TORCHAT_COMPILED_ONION_URL").map(ToOwned::to_owned))
        .context("desktop engine stdio requires a compiled onion or --server-url")?;
    value.parse().context("parse --server-url")
}

pub(crate) fn start_tor(
    cli: &Cli,
) -> Result<(
    TorRuntime,
    std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
)> {
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
        let log_directory = database_path
            .parent()
            .map(|parent| parent.join("engine-logs"));
        let (tor_runtime, status_rx) = start_tor(&cli)?;
        let socks_url: Url = tor_runtime
            .socks_url()
            .parse()
            .context("parse SOCKS5 URL")?;
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
            pump_engine_events(&mut engine).await?;

            let line = match request_rx.recv_timeout(std::time::Duration::from_millis(50)) {
                Ok(value) => value,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let envelope: EngineCommandEnvelope = match serde_json::from_str(&line) {
                Ok(value) => value,
                Err(error) => {
                    write_json_line(EngineEvent::Fatal {
                        error: EngineFatalError {
                            code: "invalid_command_envelope".to_owned(),
                            message: error.to_string(),
                        },
                    })?;
                    continue;
                }
            };
            let request_id = envelope.request_id.clone();
            let shutdown = matches!(&envelope.command, EngineCommand::Shutdown);
            if let Err(error) = engine.submit(request_id.clone(), envelope.command).await {
                write_json_line(EngineEvent::Fatal {
                    error: EngineFatalError {
                        code: "engine_submit_failed".to_owned(),
                        message: error.to_string(),
                    },
                })?;
                continue;
            }
            wait_for_response(&mut engine, &status_rx, &mut tor_status_seq, &request_id).await?;
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
                    phase: status.phase,
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

async fn pump_engine_events(engine: &mut ClientEngine) -> Result<()> {
    while let Some(event) = engine
        .poll_timeout(std::time::Duration::from_millis(5))
        .await
    {
        write_json_line(event)?;
    }
    Ok(())
}

pub(crate) async fn wait_for_response(
    engine: &mut ClientEngine,
    status_rx: &std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
    tor_status_seq: &mut u64,
    request_id: &str,
) -> Result<()> {
    loop {
        drain_tor_statuses(engine, status_rx, tor_status_seq).await?;
        let Some(event) = engine
            .poll_timeout(std::time::Duration::from_millis(50))
            .await
        else {
            continue;
        };
        let is_response = matches!(
            &event,
            EngineEvent::Response {
                request_id: value,
                ..
            } if value == request_id
        );
        write_json_line(event)?;
        if is_response {
            return Ok(());
        }
    }
}
