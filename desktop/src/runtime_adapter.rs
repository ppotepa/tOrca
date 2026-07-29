use anyhow::Result;
use torchat_client_runtime::{
    ClientRuntime, InviteCode, PairingItem, RuntimeError, RuntimeEvent, RuntimeRequest,
    RuntimeResult, RuntimeTorStatus, RuntimeTransport, SystemRuntimeClock,
};

use crate::{
    DesktopState, runtime_storage::DesktopRuntimeStorage as DesktopRuntimeStorageAdapter,
    transport::RelayCommand,
};

type DesktopClientRuntime<'a> =
    ClientRuntime<DesktopRuntimeStorageAdapter<'a>, LocalRuntimeTransport, SystemRuntimeClock>;

fn with_client_runtime<T>(
    state: &mut DesktopState,
    remote_pairing_inbox: Vec<PairingItem>,
    f: impl FnOnce(&mut DesktopClientRuntime<'_>) -> Result<T>,
) -> Result<(T, Vec<RuntimeEvent>)> {
    let relay_commands = state.relay_commands.clone();
    let session = std::mem::take(&mut state.client_runtime_session);
    let mut runtime = ClientRuntime::with_session(
        DesktopRuntimeStorageAdapter { state },
        LocalRuntimeTransport {
            relay_commands,
            remote_pairing_inbox,
        },
        SystemRuntimeClock,
        session,
    );
    let output = f(&mut runtime);
    let events = runtime.drain_events();
    let (_, _, _, session) = runtime.into_parts_with_session();
    state.client_runtime_session = session;
    match output {
        Ok(value) => Ok((value, events)),
        Err(error) => {
            state.enqueue_runtime_events(events);
            Err(error)
        }
    }
}

pub(crate) fn dispatch_local_runtime_command_with_events(
    state: &mut DesktopState,
    method: &str,
    params: serde_json::Value,
) -> Result<(serde_json::Value, Vec<RuntimeEvent>)> {
    let request = RuntimeRequest {
        id: None,
        method: method.to_owned(),
        params,
    };
    let (response, events) = with_client_runtime(
        state,
        Vec::new(),
        |runtime: &mut DesktopClientRuntime<'_>| Ok(runtime.dispatch_request(request)),
    )?;
    if response.ok {
        Ok((response.result.unwrap_or(serde_json::Value::Null), events))
    } else {
        state.enqueue_runtime_events(events);
        anyhow::bail!(
            "{}",
            response
                .error
                .unwrap_or_else(|| format!("runtime command failed: {method}"))
        )
    }
}

pub(crate) fn dispatch_local_runtime_command(
    state: &mut DesktopState,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let (value, events) = dispatch_local_runtime_command_with_events(state, method, params)?;
    state.enqueue_runtime_events(events);
    Ok(value)
}

pub(crate) fn merge_remote_pairing_inbox_with_runtime(
    state: &mut DesktopState,
    items: Vec<crate::model::PairingInboxItem>,
) -> Result<Vec<RuntimeEvent>> {
    let remote_pairing_inbox = torchat_client_runtime::runtime_pairing_items_from_iter(items);
    let (_, events) = with_client_runtime(
        state,
        remote_pairing_inbox,
        |runtime: &mut DesktopClientRuntime<'_>| {
            runtime
                .pairing_inbox()
                .map_err(|error| anyhow::anyhow!("{error}"))
        },
    )?;
    Ok(events)
}

pub(crate) fn open_conversation_with_runtime(
    state: &mut DesktopState,
    peer: &str,
) -> Result<Vec<RuntimeEvent>> {
    let (_, events) = dispatch_local_runtime_command_with_events(
        state,
        "openConversation",
        serde_json::json!({ "id": peer }),
    )?;
    Ok(events)
}

struct LocalRuntimeTransport {
    relay_commands: tokio::sync::mpsc::Sender<RelayCommand>,
    remote_pairing_inbox: Vec<PairingItem>,
}

impl RuntimeTransport for LocalRuntimeTransport {
    fn connect(&mut self) -> RuntimeResult<RuntimeTorStatus> {
        Err(RuntimeError::Unavailable(
            "desktop local runtime adapter has no transport".into(),
        ))
    }

    fn status(&self) -> RuntimeTorStatus {
        RuntimeTorStatus {
            phase: torchat_client_runtime::RuntimeStatusPhase::Offline,
            label: "offline".into(),
            detail: String::new(),
            progress: None,
            latency_ms: None,
            retry_attempt: 0,
        }
    }

    fn update_profile(&mut self, nickname: &str) -> RuntimeResult<()> {
        self.relay_commands
            .try_send(RelayCommand::UpdateNickname(nickname.to_owned()))
            .map_err(|_| RuntimeError::Unavailable("relay actor stopped".into()))
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        Err(RuntimeError::Unavailable(
            "desktop local runtime adapter has no transport".into(),
        ))
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        Err(RuntimeError::Unavailable(
            "desktop local runtime adapter has no transport".into(),
        ))
    }

    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(std::mem::take(&mut self.remote_pairing_inbox))
    }
}
