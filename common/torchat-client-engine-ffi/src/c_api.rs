#![allow(unsafe_op_in_unsafe_fn)]
#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};

use tokio::time::Duration;
use torchat_client_engine::{
    ClientEngine, EngineCommandEnvelope, EngineConfig, EngineError, PlatformFact,
};

use crate::{
    handle::{EngineHandle, EngineHandleState},
    json,
};

#[repr(C)]
pub struct OpaqueEngineHandle {
    _private: [u8; 0],
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
        .ok_or_else(|| EngineError::Closed("engine handle is null"))
}

unsafe fn handle_mut<'a>(
    value: *mut OpaqueEngineHandle,
) -> Result<&'a mut EngineHandle, EngineError> {
    value
        .cast::<EngineHandle>()
        .as_mut()
        .ok_or_else(|| EngineError::Closed("engine handle is null"))
}

fn state_mut(handle: &EngineHandle) -> Result<std::sync::MutexGuard<'_, EngineHandleState>, EngineError> {
    handle
        .state
        .lock()
        .map_err(|_| EngineError::Closed("engine handle is poisoned"))
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
    LAST_ERROR.with(|slot| {
        slot.borrow_mut()
            .take()
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
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
        let engine = ClientEngine::new(config)?;
        Ok(into_opaque(Box::new(EngineHandle {
            runtime,
            state: std::sync::Mutex::new(EngineHandleState {
                engine,
                started: false,
                shutdown: false,
            }),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_start(value: *mut OpaqueEngineHandle) -> i32 {
    protected(|| {
        let handle = handle_ref(value)?;
        let mut state = state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        if state.started {
            return Ok(0);
        }
        handle.runtime.block_on(state.engine.start())?;
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
        let state = state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        handle
            .runtime
            .block_on(state.engine.submit(envelope.request_id, envelope.command))?;
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
        let handle = handle_mut(value)?;
        let mut state = state_mut(handle)?;
        let event = if timeout_ms == 0 {
            state.engine.poll().ok()
        } else {
            handle
                .runtime
                .block_on(state.engine.poll_timeout(Duration::from_millis(timeout_ms)))
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
        let state = state_mut(handle)?;
        if state.shutdown {
            return Err(EngineError::Closed("engine handle is shutdown"));
        }
        handle
            .runtime
            .block_on(state.engine.submit_platform_fact("platform-fact", fact))?;
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_shutdown(value: *mut OpaqueEngineHandle) {
    let _ = protected(|| {
        let handle = handle_ref(value)?;
        let mut state = state_mut(handle)?;
        if state.shutdown {
            return Ok(());
        }
        state.engine.shutdown();
        state.shutdown = true;
        Ok(())
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_engine_free(value: *mut OpaqueEngineHandle) {
    if !value.is_null() {
        let _ = protected(|| {
            let handle = handle_ref(value)?;
            let mut state = state_mut(handle)?;
            if !state.shutdown {
                state.engine.shutdown();
                state.shutdown = true;
            }
            Ok(())
        });
        drop(Box::from_raw(value.cast::<EngineHandle>()));
    }
}
