#![allow(unsafe_op_in_unsafe_fn)]

use std::{
    cell::RefCell,
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};

use serde_json::json;

use crate::{
    abi::FfiStatus,
    c_api::{
        MlsEpochGetCallback, MlsEpochSetCallback, OpaqueEngineHandle, torchat_client_engine_free,
        torchat_client_engine_free_string, torchat_client_engine_last_error,
        torchat_client_engine_new, torchat_client_engine_new_with_mls_epoch_anchor,
        torchat_client_engine_platform_fact_json, torchat_client_engine_poll_json,
        torchat_client_engine_shutdown, torchat_client_engine_start,
        torchat_client_engine_submit_json,
    },
};

thread_local! {
    static LAST_PROBLEM: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn clear_problem() {
    LAST_PROBLEM.with(|slot| *slot.borrow_mut() = None);
}

fn set_problem(status: FfiStatus, diagnostic_context: impl Into<String>) {
    let diagnostic_context = diagnostic_context.into().replace('\0', " ");
    let (code, category, retryable) = match status {
        FfiStatus::Ok => ("ok", "internal", false),
        FfiStatus::InvalidArgument => ("invalid_input", "validation", false),
        FfiStatus::InvalidHandle => ("invalid_handle", "validation", false),
        FfiStatus::AlreadyShutdown => ("already_shutdown", "availability", false),
        FfiStatus::Timeout => ("temporarily_unavailable", "availability", true),
        FfiStatus::InternalError => ("internal", "internal", false),
        FfiStatus::PanicContained => ("panic_contained", "internal", false),
        FfiStatus::AbiMismatch => ("abi_mismatch", "validation", false),
    };
    let payload = json!({
        "code": code,
        "category": category,
        "retryable": retryable,
        "diagnosticContext": diagnostic_context,
    })
    .to_string();
    LAST_PROBLEM.with(|slot| {
        *slot.borrow_mut() = CString::new(payload).ok();
    });
}

unsafe fn take_legacy_error() -> String {
    let pointer = torchat_client_engine_last_error();
    if pointer.is_null() {
        return "client engine operation failed".to_owned();
    }
    let message = CStr::from_ptr(pointer).to_string_lossy().into_owned();
    torchat_client_engine_free_string(pointer);
    message
}

fn status_from_legacy_error(default: FfiStatus, message: &str) -> FfiStatus {
    let normalized = message.to_ascii_lowercase();
    if normalized.contains("null") || normalized.contains("missing") {
        return FfiStatus::InvalidArgument;
    }
    if normalized.contains("shutdown") {
        return FfiStatus::AlreadyShutdown;
    }
    if normalized.contains("timeout") {
        return FfiStatus::Timeout;
    }
    default
}

unsafe fn protected_status(operation: impl FnOnce() -> FfiStatus) -> i32 {
    clear_problem();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(status) => status.code(),
        Err(_) => {
            set_problem(
                FfiStatus::PanicContained,
                "client engine panic was contained at the ABI boundary",
            );
            FfiStatus::PanicContained.code()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn torca_engine_last_problem_json() -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        LAST_PROBLEM.with(|slot| {
            slot.borrow_mut()
                .take()
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut())
        })
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `config_json` must be non-null while `config_len` is nonzero, and
/// `out_handle` must point to writable storage.
pub unsafe extern "C" fn torca_engine_new_v1(
    config_json: *const u8,
    config_len: usize,
    out_handle: *mut *mut OpaqueEngineHandle,
) -> i32 {
    protected_status(|| {
        if out_handle.is_null() {
            set_problem(FfiStatus::InvalidArgument, "out_handle must not be null");
            return FfiStatus::InvalidArgument;
        }
        *out_handle = std::ptr::null_mut();
        if config_len > 0 && config_json.is_null() {
            set_problem(
                FfiStatus::InvalidArgument,
                "config_json must not be null when config_len is non-zero",
            );
            return FfiStatus::InvalidArgument;
        }
        let handle = torchat_client_engine_new(config_json, config_len);
        if handle.is_null() {
            let message = take_legacy_error();
            let status = status_from_legacy_error(FfiStatus::InvalidArgument, &message);
            set_problem(status, message);
            return status;
        }
        *out_handle = handle;
        FfiStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `config_json` must be non-null while `config_len` is nonzero, and
/// `out_handle` must point to writable storage. Any provided callbacks must
/// remain valid for the lifetime of the returned engine handle.
pub unsafe extern "C" fn torca_engine_new_with_mls_epoch_anchor_v1(
    config_json: *const u8,
    config_len: usize,
    get_epoch: Option<MlsEpochGetCallback>,
    set_epoch: Option<MlsEpochSetCallback>,
    out_handle: *mut *mut OpaqueEngineHandle,
) -> i32 {
    protected_status(|| {
        if out_handle.is_null() {
            set_problem(FfiStatus::InvalidArgument, "out_handle must not be null");
            return FfiStatus::InvalidArgument;
        }
        *out_handle = std::ptr::null_mut();
        if get_epoch.is_none() || set_epoch.is_none() {
            set_problem(
                FfiStatus::InvalidArgument,
                "MLS epoch callbacks must both be provided",
            );
            return FfiStatus::InvalidArgument;
        }
        let handle = torchat_client_engine_new_with_mls_epoch_anchor(
            config_json,
            config_len,
            get_epoch,
            set_epoch,
        );
        if handle.is_null() {
            let message = take_legacy_error();
            let status = status_from_legacy_error(FfiStatus::InvalidArgument, &message);
            set_problem(status, message);
            return status;
        }
        *out_handle = handle;
        FfiStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be a valid engine handle returned by a prior constructor and
/// not yet freed.
pub unsafe extern "C" fn torca_engine_start_v1(handle: *mut OpaqueEngineHandle) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(FfiStatus::InvalidHandle, "engine handle must not be null");
            return FfiStatus::InvalidHandle;
        }
        if torchat_client_engine_start(handle) == 0 {
            return FfiStatus::Ok;
        }
        let message = take_legacy_error();
        let status = status_from_legacy_error(FfiStatus::InternalError, &message);
        set_problem(status, message);
        status
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be a valid, not-yet-freed engine handle. `request_json` must
/// be non-null while `request_len` is nonzero.
pub unsafe extern "C" fn torca_engine_submit_json_v1(
    handle: *mut OpaqueEngineHandle,
    request_json: *const u8,
    request_len: usize,
) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(FfiStatus::InvalidHandle, "engine handle must not be null");
            return FfiStatus::InvalidHandle;
        }
        if request_len > 0 && request_json.is_null() {
            set_problem(
                FfiStatus::InvalidArgument,
                "request_json must not be null when request_len is non-zero",
            );
            return FfiStatus::InvalidArgument;
        }
        if torchat_client_engine_submit_json(handle, request_json, request_len) == 0 {
            return FfiStatus::Ok;
        }
        let message = take_legacy_error();
        let status = status_from_legacy_error(FfiStatus::InternalError, &message);
        set_problem(status, message);
        status
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be a valid, not-yet-freed engine handle. `fact_json` must be
/// non-null while `fact_len` is nonzero.
pub unsafe extern "C" fn torca_engine_platform_fact_json_v1(
    handle: *mut OpaqueEngineHandle,
    fact_json: *const u8,
    fact_len: usize,
) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(FfiStatus::InvalidHandle, "engine handle must not be null");
            return FfiStatus::InvalidHandle;
        }
        if fact_len > 0 && fact_json.is_null() {
            set_problem(
                FfiStatus::InvalidArgument,
                "fact_json must not be null when fact_len is non-zero",
            );
            return FfiStatus::InvalidArgument;
        }
        if torchat_client_engine_platform_fact_json(handle, fact_json, fact_len) == 0 {
            return FfiStatus::Ok;
        }
        let message = take_legacy_error();
        let status = status_from_legacy_error(FfiStatus::InternalError, &message);
        set_problem(status, message);
        status
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be a valid, not-yet-freed engine handle. `out_json` must point
/// to writable storage; the caller assumes ownership of any string it receives.
pub unsafe extern "C" fn torca_engine_poll_json_v1(
    handle: *mut OpaqueEngineHandle,
    timeout_ms: u64,
    out_json: *mut *mut c_char,
) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(FfiStatus::InvalidHandle, "engine handle must not be null");
            return FfiStatus::InvalidHandle;
        }
        if out_json.is_null() {
            set_problem(FfiStatus::InvalidArgument, "out_json must not be null");
            return FfiStatus::InvalidArgument;
        }
        *out_json = std::ptr::null_mut();
        let value = torchat_client_engine_poll_json(handle, timeout_ms);
        if value.is_null() {
            let message = take_legacy_error();
            let status = status_from_legacy_error(FfiStatus::InternalError, &message);
            set_problem(status, message);
            return status;
        }
        *out_json = value;
        FfiStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be a valid engine handle obtained from a constructor and not
/// yet freed.
pub unsafe extern "C" fn torca_engine_shutdown_v1(handle: *mut OpaqueEngineHandle) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(FfiStatus::InvalidHandle, "engine handle must not be null");
            return FfiStatus::InvalidHandle;
        }
        torchat_client_engine_shutdown(handle);
        FfiStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must point to a valid engine-handle pointer. The engine is freed
/// and the pointer is nulled; the caller must not use the handle afterwards.
pub unsafe extern "C" fn torca_engine_free_v1(handle: *mut *mut OpaqueEngineHandle) -> i32 {
    protected_status(|| {
        if handle.is_null() {
            set_problem(
                FfiStatus::InvalidArgument,
                "handle pointer must not be null",
            );
            return FfiStatus::InvalidArgument;
        }
        let value = *handle;
        if value.is_null() {
            return FfiStatus::Ok;
        }
        torchat_client_engine_free(value);
        *handle = std::ptr::null_mut();
        FfiStatus::Ok
    })
}
