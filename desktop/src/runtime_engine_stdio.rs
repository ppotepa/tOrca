use anyhow::{Context, Result, bail};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::io::{BufRead, Write};
use torchat_client_engine::{
    ClientEngine, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError, EngineEvent,
    EngineFatalError, PlatformAction, PlatformFact, PlatformKind, anti_rollback::MlsEpochAnchor,
    config::SecretBytes,
};
use url::Url;

use crate::{cli::Cli, identity_store, tor_runtime::TorRuntime};

struct DesktopMlsEpochAnchor {
    namespace: String,
}

impl DesktopMlsEpochAnchor {
    fn new(database_path: &std::path::Path) -> Self {
        let digest = Sha256::digest(database_path.to_string_lossy().as_bytes());
        Self {
            namespace: digest.iter().map(|byte| format!("{byte:02x}")).collect(),
        }
    }

    fn entry(&self, conversation_id: &str) -> Result<keyring::Entry, EngineError> {
        let digest = Sha256::digest(conversation_id.as_bytes());
        let account = format!(
            "mls-epoch-{}-{}",
            self.namespace,
            digest
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
        );
        keyring::Entry::new("org.torchat.desktop", &account)
            .map_err(|error| EngineError::Storage(format!("create MLS epoch vault entry: {error}")))
    }
}

impl MlsEpochAnchor for DesktopMlsEpochAnchor {
    type Error = EngineError;

    fn highest_epoch(&self, conversation_id: &str) -> Result<Option<u64>, Self::Error> {
        match self.entry(conversation_id)?.get_secret() {
            Ok(value) => {
                let bytes: [u8; 8] = value.try_into().map_err(|_| {
                    EngineError::Storage("MLS epoch vault value has invalid length".to_owned())
                })?;
                Ok(Some(u64::from_be_bytes(bytes)))
            }
            Err(error) if matches!(&error, keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(EngineError::Storage(format!(
                "read MLS epoch vault value: {error}"
            ))),
        }
    }

    fn record_epoch(&mut self, conversation_id: &str, epoch: u64) -> Result<(), Self::Error> {
        self.entry(conversation_id)?
            .set_secret(&epoch.to_be_bytes())
            .map_err(|error| EngineError::Storage(format!("write MLS epoch vault value: {error}")))
    }
}

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
        return TorRuntime::start(binary, &data_dir, cli.relay_socks5_proxy.clone());
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
        let database_key_path = identity_store::database_key_path(cli.identity_file.as_deref())?;
        let database_key = identity_store::load_or_create_database_key(&database_key_path)?;
        let log_directory = database_path
            .parent()
            .map(|parent| parent.join("engine-logs"));
        let config = EngineConfig {
            database_path,
            database_key: SecretBytes(database_key),
            identity_private_key: SecretBytes(identity.private_key_bytes().to_vec()),
            relay_onion_url: relay_url(&cli)?,
            initial_socks5_url: None,
            log_directory,
            platform: platform_kind(),
        };
        let mut mls_anchor = DesktopMlsEpochAnchor::new(&database_path);
        let mut engine = ClientEngine::new_with_anchor(config, &mut mls_anchor)?;
        engine.start().await?;
        let (tor_runtime, status_rx) = start_tor(&cli)?;

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
        let mut tor_endpoint_published = false;
        let mut pending_platform_action: Option<PlatformAction> = None;
        loop {
            drain_tor_statuses(
                &engine,
                &tor_runtime,
                &status_rx,
                &mut tor_status_seq,
                &mut tor_endpoint_published,
            )
            .await?;
            flush_pending_platform_action(&engine, &tor_runtime, &mut pending_platform_action)
                .await?;
            pump_engine_events(&mut engine, &tor_runtime, &mut pending_platform_action).await?;

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
            if let Err(error) = engine.submit_envelope(envelope).await {
                write_json_line(EngineEvent::Fatal {
                    error: EngineFatalError {
                        code: "engine_submit_failed".to_owned(),
                        message: error.to_string(),
                    },
                })?;
                continue;
            }
            wait_for_response(
                &mut engine,
                &tor_runtime,
                &status_rx,
                &mut tor_status_seq,
                &mut tor_endpoint_published,
                &mut pending_platform_action,
                &request_id,
            )
            .await?;
            if shutdown {
                break;
            }
        }
        Ok(())
    })
}

pub(crate) async fn drain_tor_statuses(
    engine: &ClientEngine,
    tor_runtime: &TorRuntime,
    status_rx: &std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
    tor_status_seq: &mut u64,
    tor_endpoint_published: &mut bool,
) -> Result<()> {
    while let Ok(status) = status_rx.try_recv() {
        let is_ready_status = matches!(status.phase, torchat_client_engine::TorPhase::Ready);
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
        if !*tor_endpoint_published && is_ready_status && tor_runtime.is_ready() {
            engine
                .submit_platform_fact(
                    "desktop-tor-endpoint",
                    PlatformFact::TorEndpointAvailable {
                        socks5_url: tor_runtime.socks_url().to_owned(),
                    },
                )
                .await?;
            *tor_endpoint_published = true;
        }
    }
    // A live control port only proves that the local Tor process is running.
    // It does not prove that bootstrap finished or that a fresh onion circuit
    // can be built. Publishing the SOCKS endpoint here started relay requests
    // during `Bootstrapped 0..95%`, consumed their full timeout and then sent
    // the startup screen into a long retry ladder. The Ready status above is
    // emitted only for `Bootstrapped 100%` (or by the explicit external-Tor
    // runtime), so it is the sole authority for this fact.
    Ok(())
}

async fn pump_engine_events(
    engine: &mut ClientEngine,
    tor_runtime: &TorRuntime,
    pending_platform_action: &mut Option<PlatformAction>,
) -> Result<()> {
    while let Some(event) = engine
        .poll_timeout(std::time::Duration::from_millis(5))
        .await
    {
        handle_engine_event(engine, tor_runtime, pending_platform_action, event).await?;
    }
    Ok(())
}

async fn flush_pending_platform_action(
    engine: &ClientEngine,
    tor_runtime: &TorRuntime,
    pending_platform_action: &mut Option<PlatformAction>,
) -> Result<()> {
    let Some(action) = pending_platform_action.clone() else {
        return Ok(());
    };
    if !tor_runtime.is_ready() {
        return Ok(());
    }
    *pending_platform_action = None;
    apply_platform_action(engine, tor_runtime, action).await
}

async fn handle_engine_event(
    engine: &ClientEngine,
    tor_runtime: &TorRuntime,
    pending_platform_action: &mut Option<PlatformAction>,
    event: EngineEvent,
) -> Result<()> {
    let action = match event {
        EngineEvent::PlatformAction { action } => action,
        event => return write_json_line(event),
    };
    if !tor_runtime.is_ready() {
        *pending_platform_action = Some(action);
        return Ok(());
    }
    apply_platform_action(engine, tor_runtime, action).await
}

async fn apply_platform_action(
    engine: &ClientEngine,
    tor_runtime: &TorRuntime,
    action: PlatformAction,
) -> Result<()> {
    let result = match action {
        PlatformAction::ConfigureOnionService {
            local_port,
            virtual_port,
            generation,
        } => tor_runtime
            .configure_onion_service(local_port, virtual_port, generation)
            .map(|hostname| (hostname, local_port, virtual_port, generation)),
        PlatformAction::RotateOnionService { generation } => tor_runtime
            .rotate_onion_service(generation)
            .map(|(hostname, local_port, virtual_port)| {
                (hostname, local_port, virtual_port, generation)
            }),
    };
    match result {
        Ok((onion_address, local_port, virtual_port, generation)) => {
            let _ = write_json_line(EngineEvent::Log {
                log: torchat_client_engine::EngineLogEvent {
                    level: "info".into(),
                    message: format!(
                        "peer onion service configured generation={generation} local_port={local_port} virtual_port={virtual_port}"
                    ),
                },
            });
            engine
                .submit_platform_fact(
                    format!("desktop-onion-service-{generation}"),
                    PlatformFact::OnionServiceAvailable {
                        onion_address,
                        virtual_port,
                        generation,
                    },
                )
                .await?;
            Ok(())
        }
        Err(error) => {
            engine
                .submit_platform_fact(
                    "desktop-onion-service-lost",
                    PlatformFact::OnionServiceLost {
                        reason: error.to_string(),
                    },
                )
                .await?;
            // A transient Tor/control-plane failure must not tear down the
            // shared runtime. The engine keeps its queue and will retry when
            // the platform reports Tor/onion availability again.
            let _ = write_json_line(EngineEvent::Log {
                log: torchat_client_engine::EngineLogEvent {
                    level: "warn".into(),
                    message: format!("onion service configuration failed: {error:#}"),
                },
            });
            Ok(())
        }
    }
}

pub(crate) async fn wait_for_response(
    engine: &mut ClientEngine,
    tor_runtime: &TorRuntime,
    status_rx: &std::sync::mpsc::Receiver<crate::tor_runtime::TorStatus>,
    tor_status_seq: &mut u64,
    tor_endpoint_published: &mut bool,
    pending_platform_action: &mut Option<PlatformAction>,
    request_id: &str,
) -> Result<()> {
    loop {
        drain_tor_statuses(
            engine,
            tor_runtime,
            status_rx,
            tor_status_seq,
            tor_endpoint_published,
        )
        .await?;
        flush_pending_platform_action(engine, tor_runtime, pending_platform_action).await?;
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
        let is_platform_action = matches!(&event, EngineEvent::PlatformAction { .. });
        handle_engine_event(engine, tor_runtime, pending_platform_action, event).await?;
        if is_platform_action {
            continue;
        }
        if is_response {
            return Ok(());
        }
    }
}
