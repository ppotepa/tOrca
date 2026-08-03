#![allow(unsafe_op_in_unsafe_fn)]
#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};

use tokio::time::Duration;
use torchat_client_engine::{
    ClientEngine, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError, PlatformFact,
    anti_rollback::MlsEpochAnchor,
};

use crate::{
    handle::{EngineHandle, EngineHandleCommandState},
    json,
};

#[repr(C)]
pub struct OpaqueEngineHandle {
    _private: [u8; 0],
}

pub type MlsEpochGetCallback = unsafe extern "C" fn(
    conversation_id: *const u8,
    conversation_id_len: usize,
    epoch_out: *mut u64,
) -> i32;
pub type MlsEpochSetCallback =
    unsafe extern "C" fn(conversation_id: *const u8, conversation_id_len: usize, epoch: u64) -> i32;

struct FfiMlsEpochAnchor {
    get: MlsEpochGetCallback,
    set: MlsEpochSetCallback,
}

impl MlsEpochAnchor for FfiMlsEpochAnchor {
    type Error = EngineError;

    fn highest_epoch(&self, conversation_id: &str) -> Result<Option<u64>, Self::Error> {
        let mut epoch = 0_u64;
        let result =
            unsafe { (self.get)(conversation_id.as_ptr(), conversation_id.len(), &mut epoch) };
        match result {
            0 => Ok(Some(epoch)),
            1 => Ok(None),
            code => Err(EngineError::Storage(format!(
                "MLS epoch get callback failed: {code}"
            ))),
        }
    }

    fn record_epoch(&mut self, conversation_id: &str, epoch: u64) -> Result<(), Self::Error> {
        let result = unsafe { (self.set)(conversation_id.as_ptr(), conversation_id.len(), epoch) };
        if result == 0 {
            Ok(())
        } else {
            Err(EngineError::Storage(format!(
                "MLS epoch set callback failed: {result}"
            )))
        }
    }
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const { std::cell::RefCell::new(None) };
}

fn set_error(message: impl Into<String>) {
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(message.into().replace('\0', " ")).ok();
    });
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn c_string(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn into_opaque(handle: Box<EngineHandle>) -> *mut OpaqueEngineHandle {
    Box::into_raw(handle).cast()
}

unsafe fn handle_ref<'a>(value: *mut OpaqueEngineHandle) -> Result<&'a EngineHandle, EngineError> {
    value
        .cast::<EngineHandle>()
        .as_ref()
        .ok_or(EngineError::Closed("engine handle is null"))
}

fn command_state_mut(
    handle: &EngineHandle,
) -> Result<std::sync::MutexGuard<'_, EngineHandleCommandState>, EngineError> {
    handle
        .command_state
        .lock()
        .map_err(|_| EngineError::Closed("engine handle is poisoned"))
}

fn event_receiver_mut(
    handle: &EngineHandle,
) -> Result<std::sync::MutexGuard<'_, torchat_client_engine::event::EngineEventReceiver>, EngineError>
{
    handle
        .events
        .lock()
        .map_err(|_| EngineError::Closed("engine event receiver is poisoned"))
}

unsafe fn input<'a>(data: *const u8, len: usize) -> Result<&'a [u8], EngineError> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err(EngineError::InvalidCommand("null buffer".to_owned()));
    }
    Ok(std::slice::from_raw_parts(data, len))
}

unsafe fn protected<T>(operation: impl FnOnce() -> Result<T, EngineError>) -> Option<T> {
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => Some(value),
        Ok(Err(error)) => {
            set_error(error.to_string());
            None
        }
        Err(_) => {
            set_error("client engine panicked");
            None
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn torchat_client_engine_last_error() -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        LAST_ERROR.with(|slot| {
            slot.borrow_mut()
                .take()
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut())
        })
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_free_string(value: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !value.is_null() {
            drop(CString::from_raw(value));
        }
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_new(
    config_json: *const u8,
    config_len: usize,
) -> *mut OpaqueEngineHandle {
    protected(|| {
        let config: EngineConfig = json::decode(input(config_json, config_len)?)?;
        let runtime = tokio::runtime::Runtime::new()
            .map_err(|error| EngineError::InvalidConfig(error.to_string()))?;
        let engine = runtime.block_on(async { ClientEngine::new(config) })?;
        let (commands, events, shutdown_token) = engine.into_parts();
        Ok(into_opaque(Box::new(EngineHandle {
            runtime,
            command_state: std::sync::Mutex::new(EngineHandleCommandState {
                commands,
                shutdown_token,
                started: false,
                shutdown: false,
            }),
            events: std::sync::Mutex::new(events),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_new_with_mls_epoch_anchor(
    config_json: *const u8,
    config_len: usize,
    get_epoch: Option<MlsEpochGetCallback>,
    set_epoch: Option<MlsEpochSetCallback>,
) -> *mut OpaqueEngineHandle {
    protected(|| {
        let config: EngineConfig = json::decode(input(config_json, config_len)?)?;
        let get_epoch = get_epoch.ok_or_else(|| {
            EngineError::InvalidConfig("MLS epoch get callback is missing".to_owned())
        })?;
        let set_epoch = set_epoch.ok_or_else(|| {
            EngineError::InvalidConfig("MLS epoch set callback is missing".to_owned())
        })?;
        let runtime = tokio::runtime::Runtime::new()
            .map_err(|error| EngineError::InvalidConfig(error.to_string()))?;
        let mut anchor = FfiMlsEpochAnchor {
            get: get_epoch,
            set: set_epoch,
        };
        let engine =
            runtime.block_on(async { ClientEngine::new_with_anchor(config, &mut anchor) })?;
        let (commands, events, shutdown_token) = engine.into_parts();
        Ok(into_opaque(Box::new(EngineHandle {
            runtime,
            command_state: std::sync::Mutex::new(EngineHandleCommandState {
                commands,
                shutdown_token,
                started: false,
                shutdown: false,
            }),
            events: std::sync::Mutex::new(events),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_start(value: *mut OpaqueEngineHandle) -> i32 {
    protected(|| {
        let handle = handle_ref(value)?;
        let mut state = command_state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        if state.started {
            return Ok(0);
        }
        let commands = state.commands.clone();
        handle.runtime.block_on(async move {
            commands
                .send(EngineCommandEnvelope {
                    request_id: "engine-start-bootstrap".to_owned(),
                    command_id: None,
                    command: EngineCommand::Bootstrap,
                })
                .await
                .map_err(|_| EngineError::Closed("engine command channel is closed"))
        })?;
        state.started = true;
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_submit_json(
    value: *mut OpaqueEngineHandle,
    request_json: *const u8,
    request_len: usize,
) -> i32 {
    protected(|| {
        let handle = handle_ref(value)?;
        let envelope: EngineCommandEnvelope = json::decode(input(request_json, request_len)?)?;
        let state = command_state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        if !state.started {
            return Err(EngineError::Closed("engine handle is not started"));
        }
        let commands = state.commands.clone();
        handle.runtime.block_on(async move {
            commands
                .send(envelope)
                .await
                .map_err(|_| EngineError::Closed("engine command channel is closed"))
        })?;
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_poll_json(
    value: *mut OpaqueEngineHandle,
    timeout_ms: u64,
) -> *mut c_char {
    protected(|| {
        let handle = handle_ref(value)?;
        let mut events = event_receiver_mut(handle)?;
        let event = if timeout_ms == 0 {
            events.try_recv().ok()
        } else {
            handle
                .runtime
                .block_on(events.recv_timeout(Duration::from_millis(timeout_ms)))
        };
        json::encode(&event)
    })
    .map(c_string)
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_platform_fact_json(
    value: *mut OpaqueEngineHandle,
    fact_json: *const u8,
    fact_len: usize,
) -> i32 {
    protected(|| {
        let handle = handle_ref(value)?;
        let fact: PlatformFact = json::decode(input(fact_json, fact_len)?)?;
        let state = command_state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        if !state.started {
            return Err(EngineError::Closed("engine handle is not started"));
        }
        let commands = state.commands.clone();
        handle.runtime.block_on(async move {
            commands
                .send(EngineCommandEnvelope {
                    request_id: "platform-fact".to_owned(),
                    command_id: None,
                    command: EngineCommand::PlatformFact { fact },
                })
                .await
                .map_err(|_| EngineError::Closed("engine command channel is closed"))
        })?;
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_shutdown(value: *mut OpaqueEngineHandle) {
    let _ = protected(|| {
        let handle = handle_ref(value)?;
        let mut state = command_state_mut(handle)?;
        if state.shutdown {
            return Ok(());
        }
        state.shutdown_token.cancel();
        state.shutdown = true;
        Ok(())
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_free(value: *mut OpaqueEngineHandle) {
    if value.is_null() {
        return;
    }
    let _ = protected(|| {
        let handle = Box::from_raw(value.cast::<EngineHandle>());
        {
            let mut state = command_state_mut(&handle)?;
            if !state.shutdown {
                state.shutdown_token.cancel();
                state.shutdown = true;
            }
        }
        drop(handle);
        Ok(())
    });
}

#[cfg(test)]
mod tests {
    use std::{ffi::CStr, path::PathBuf};

    use serde_json::json;

    use super::*;

    fn temp_database_path(name: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock must be after unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "torchat-client-engine-ffi-{name}-{}-{nanos}.db",
            std::process::id()
        ))
    }

    fn bytes(byte: u8) -> Vec<u8> {
        vec![byte; 32]
    }

    fn config_json(database_path: &PathBuf) -> Vec<u8> {
        json!({
            "databasePath": database_path,
            "databaseKey": bytes(3),
            "identityPrivateKey": bytes(4),
            "relayOnionUrl": "http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion/",
            "initialSocks5Url": null,
            "logDirectory": null,
            "platform": "desktop"
        })
        .to_string()
        .into_bytes()
    }

    fn command_json(command_type: &str) -> Vec<u8> {
        json!({
            "requestId": "test-request",
            "command": {
                "type": command_type
            }
        })
        .to_string()
        .into_bytes()
    }

    unsafe fn take_last_error() -> String {
        let error = torchat_client_engine_last_error();
        assert!(!error.is_null(), "expected C API last_error");
        let text = CStr::from_ptr(error).to_string_lossy().into_owned();
        torchat_client_engine_free_string(error);
        text
    }

    unsafe fn take_string(value: *mut c_char) -> String {
        assert!(!value.is_null(), "expected C API string");
        let text = CStr::from_ptr(value).to_string_lossy().into_owned();
        torchat_client_engine_free_string(value);
        text
    }

    #[test]
    fn submit_after_shutdown_returns_closed_error() {
        let path = temp_database_path("submit-after-shutdown");
        let config = config_json(&path);
        let command = command_json("get_profile");

        unsafe {
            let handle = torchat_client_engine_new(config.as_ptr(), config.len());
            assert!(!handle.is_null());

            torchat_client_engine_shutdown(handle);
            assert_eq!(
                torchat_client_engine_submit_json(handle, command.as_ptr(), command.len()),
                -1
            );
            assert!(take_last_error().contains("engine handle is shutdown"));

            torchat_client_engine_free(handle);
        }

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn shutdown_and_free_are_idempotent_before_start() {
        let path = temp_database_path("double-shutdown");
        let config = config_json(&path);

        unsafe {
            let handle = torchat_client_engine_new(config.as_ptr(), config.len());
            assert!(!handle.is_null());

            torchat_client_engine_shutdown(handle);
            torchat_client_engine_shutdown(handle);
            torchat_client_engine_free(handle);
            torchat_client_engine_free(std::ptr::null_mut());
        }

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn poll_after_shutdown_returns_empty_json_without_error() {
        let path = temp_database_path("poll-after-shutdown");
        let config = config_json(&path);

        unsafe {
            let handle = torchat_client_engine_new(config.as_ptr(), config.len());
            assert!(!handle.is_null());

            torchat_client_engine_shutdown(handle);
            assert_eq!(
                take_string(torchat_client_engine_poll_json(handle, 0)),
                "null"
            );

            torchat_client_engine_free(handle);
        }

        let _ = std::fs::remove_file(path);
    }
}
