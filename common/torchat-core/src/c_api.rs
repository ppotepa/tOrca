#![allow(unsafe_op_in_unsafe_fn)]
// C ABI entry points share one pointer-safety contract: callers must pass
// valid pointers/lengths and release returned ownership with the matching free
// function. The ABI stays small and is exercised by FFI round-trip tests.
#![allow(clippy::missing_safety_doc)]

//! Small C ABI for clients that cannot consume UniFFI directly.
//!
//! The ABI deliberately exposes opaque handles and owned buffers only. Private
//! identity bytes never leave Rust through this interface.

use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{
    ContactInvite, Identity,
    mls::{DirectConversation, MlsMember},
    verify_signature,
};
use base64::Engine;

#[repr(C)]
pub struct TorchatBytes {
    pub data: *mut u8,
    pub len: usize,
}

#[repr(C)]
pub struct TorchatPair {
    pub first: TorchatBytes,
    pub second: TorchatBytes,
}

pub struct TorchatIdentity {
    identity: Identity,
    pending_member: Mutex<Option<MlsMember>>,
}

pub struct TorchatConversation {
    conversation: DirectConversation,
}

fn identity_handle(identity: Identity) -> Result<*mut TorchatIdentity, String> {
    let member = MlsMember::create(identity.public_key().as_bytes())?;
    Ok(Box::into_raw(Box::new(TorchatIdentity {
        identity,
        pending_member: Mutex::new(Some(member)),
    })))
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const { std::cell::RefCell::new(None) };
}

fn error(message: impl Into<String>) {
    let message = message.into().replace('\0', " ");
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new(message).ok());
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn string(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn bytes(value: Vec<u8>) -> TorchatBytes {
    let mut value = value.into_boxed_slice();
    let result = TorchatBytes {
        data: value.as_mut_ptr(),
        len: value.len(),
    };
    std::mem::forget(value);
    result
}

unsafe fn input(data: *const u8, len: usize) -> Result<&'static [u8], String> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err("null buffer".into());
    }
    Ok(std::slice::from_raw_parts(data, len))
}

unsafe fn protected<T>(operation: impl FnOnce() -> Result<T, String>) -> Option<T> {
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => Some(value),
        Ok(Err(message)) => {
            error(message);
            None
        }
        Err(_) => {
            error("Rust core panicked");
            None
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn torchat_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow_mut()
            .take()
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_free_bytes(value: TorchatBytes) {
    if !value.data.is_null() {
        drop(Vec::from_raw_parts(value.data, value.len, value.len));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn torchat_identity_generate() -> *mut TorchatIdentity {
    unsafe { protected(|| identity_handle(Identity::generate())) }.unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_from_private_key(
    data: *const u8,
    len: usize,
) -> *mut TorchatIdentity {
    protected(|| {
        let value = input(data, len)?;
        let bytes: [u8; 32] = value
            .try_into()
            .map_err(|_| "identity key must be 32 bytes")?;
        identity_handle(Identity::from_private_key_bytes(bytes))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_free(value: *mut TorchatIdentity) {
    if !value.is_null() {
        drop(Box::from_raw(value));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_fingerprint(
    value: *const TorchatIdentity,
) -> *mut c_char {
    if value.is_null() {
        error("identity is null");
        return std::ptr::null_mut();
    }
    string((*value).identity.fingerprint())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_installation_id(
    value: *const TorchatIdentity,
) -> *mut c_char {
    if value.is_null() {
        error("identity is null");
        return std::ptr::null_mut();
    }
    string((*value).identity.installation_id())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_public_key(value: *const TorchatIdentity) -> *mut c_char {
    if value.is_null() {
        error("identity is null");
        return std::ptr::null_mut();
    }
    string((*value).identity.public_key())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_sign(
    value: *const TorchatIdentity,
    data: *const u8,
    len: usize,
) -> *mut c_char {
    if value.is_null() {
        error("identity is null");
        return std::ptr::null_mut();
    }
    match input(data, len) {
        Ok(data) => string((*value).identity.sign(data)),
        Err(message) => {
            error(message);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_verify_signature(
    public_key: *const u8,
    public_key_len: usize,
    data: *const u8,
    data_len: usize,
    signature: *const u8,
    signature_len: usize,
) -> i32 {
    protected(|| {
        let public_key = std::str::from_utf8(input(public_key, public_key_len)?)
            .map_err(|_| "public key is not UTF-8")?;
        let signature = std::str::from_utf8(input(signature, signature_len)?)
            .map_err(|_| "signature is not UTF-8")?;
        if !verify_signature(public_key, input(data, data_len)?, signature) {
            return Err("signature verification failed".into());
        }
        Ok(())
    })
    .map(|_| 1)
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_invite(value: *const TorchatIdentity) -> *mut c_char {
    if value.is_null() {
        error("identity is null");
        return std::ptr::null_mut();
    }
    match (*value).identity.invite_payload() {
        Ok(value) => string(value),
        Err(error) => {
            self::error(error.to_string());
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_contact_invite(
    value: *const TorchatIdentity,
) -> *mut c_char {
    torchat_identity_contact_invite_with_nickname_and_recipient(
        value,
        std::ptr::null(),
        0,
        std::ptr::null(),
        0,
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_contact_invite_with_nickname(
    value: *const TorchatIdentity,
    nickname: *const u8,
    nickname_len: usize,
) -> *mut c_char {
    torchat_identity_contact_invite_with_nickname_and_recipient(
        value,
        nickname,
        nickname_len,
        std::ptr::null(),
        0,
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_contact_invite_with_nickname_and_recipient(
    value: *const TorchatIdentity,
    nickname: *const u8,
    nickname_len: usize,
    recipient: *const u8,
    recipient_len: usize,
) -> *mut c_char {
    protected(|| {
        if value.is_null() {
            return Err("identity is null".into());
        }
        let nickname = if nickname_len == 0 {
            None
        } else {
            let value = std::str::from_utf8(input(nickname, nickname_len)?)
                .map_err(|_| "nickname is not UTF-8")?
                .trim();
            if value.len() < 2 || value.chars().count() > 32 {
                return Err("nickname is invalid".into());
            }
            Some(value.to_owned())
        };
        let recipient_installation_id = if recipient_len == 0 {
            None
        } else {
            let value = std::str::from_utf8(input(recipient, recipient_len)?)
                .map_err(|_| "recipient is not UTF-8")?
                .trim();
            if value.is_empty() {
                return Err("recipient is invalid".into());
            }
            Some(value.to_owned())
        };
        let member = (*value)
            .pending_member
            .lock()
            .map_err(|_| "MLS member lock poisoned")?;
        let member = member
            .as_ref()
            .ok_or_else(|| "MLS member is being rotated".to_string())?;
        let key_package = member.key_package()?;
        (*value)
            .identity
            .contact_invite_payload(
                nickname,
                recipient_installation_id,
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key_package),
                uuid::Uuid::new_v4().to_string(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| "system clock is invalid")?
                    .as_secs()
                    + 15 * 60,
            )
            .map_err(|e| e.to_string())
    })
    .map(string)
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_mls_snapshot(
    value: *const TorchatIdentity,
) -> TorchatBytes {
    protected(|| {
        if value.is_null() {
            return Err("identity is null".into());
        }
        let member = (*value)
            .pending_member
            .lock()
            .map_err(|_| "MLS member lock poisoned")?;
        member
            .as_ref()
            .ok_or_else(|| "MLS member is being rotated".to_string())?
            .snapshot()
    })
    .map(bytes)
    .unwrap_or(TorchatBytes {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_identity_restore_mls(
    value: *const TorchatIdentity,
    data: *const u8,
    len: usize,
) -> i32 {
    protected(|| {
        if value.is_null() {
            return Err("identity is null".into());
        }
        let member =
            MlsMember::restore(input(data, len)?, (*value).identity.public_key().as_bytes())?;
        *(*value)
            .pending_member
            .lock()
            .map_err(|_| "MLS member lock poisoned")? = Some(member);
        Ok(())
    })
    .map(|_| 1)
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_validate_contact_invite(data: *const u8, len: usize) -> i32 {
    protected(|| {
        let value = std::str::from_utf8(input(data, len)?).map_err(|_| "invite is not UTF-8")?;
        ContactInvite::parse(value).map(|_| ())
    })
    .map(|_| 1)
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_contact_invite_key_package(
    data: *const u8,
    len: usize,
) -> TorchatBytes {
    protected(|| {
        let value = std::str::from_utf8(input(data, len)?).map_err(|_| "invite is not UTF-8")?;
        let invite = ContactInvite::parse(value).map_err(|e| e.to_string())?;
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(invite.key_package)
            .map_err(|_| "invalid invite KeyPackage encoding".into())
    })
    .map(bytes)
    .unwrap_or(TorchatBytes {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_create(
    identity: *const TorchatIdentity,
) -> *mut TorchatConversation {
    protected(|| {
        if identity.is_null() {
            return Err("identity is null".into());
        }
        let member = MlsMember::create((*identity).identity.public_key().as_bytes())?;
        Ok(Box::into_raw(Box::new(TorchatConversation {
            conversation: member.create_conversation()?,
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_restore(
    data: *const u8,
    len: usize,
) -> *mut TorchatConversation {
    protected(|| {
        Ok(Box::into_raw(Box::new(TorchatConversation {
            conversation: DirectConversation::restore(input(data, len)?)?,
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_accept(
    identity: *const TorchatIdentity,
    welcome: *const u8,
    welcome_len: usize,
    tree: *const u8,
    tree_len: usize,
) -> *mut TorchatConversation {
    protected(|| {
        if identity.is_null() {
            return Err("identity is null".into());
        }
        let public_key = (*identity).identity.public_key();
        let mut pending = (*identity)
            .pending_member
            .lock()
            .map_err(|_| "MLS member lock poisoned")?;
        let member = pending
            .take()
            .ok_or_else(|| "MLS member is being rotated".to_string())?;
        let snapshot = member.snapshot()?;
        match member.accept_conversation(input(welcome, welcome_len)?, input(tree, tree_len)?) {
            Ok(conversation) => {
                *pending = Some(MlsMember::create(public_key.as_bytes())?);
                Ok(Box::into_raw(Box::new(TorchatConversation {
                    conversation,
                })))
            }
            Err(error) => {
                *pending = Some(MlsMember::restore(&snapshot, public_key.as_bytes())?);
                Err(error)
            }
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_free(value: *mut TorchatConversation) {
    if !value.is_null() {
        drop(Box::from_raw(value));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_invite(
    value: *mut TorchatConversation,
    key_package: *const u8,
    len: usize,
) -> TorchatPair {
    protected(|| {
        if value.is_null() {
            return Err("conversation is null".into());
        }
        let (welcome, tree) = (*value).conversation.invite(input(key_package, len)?)?;
        Ok(TorchatPair {
            first: bytes(welcome),
            second: bytes(tree),
        })
    })
    .unwrap_or(TorchatPair {
        first: TorchatBytes {
            data: std::ptr::null_mut(),
            len: 0,
        },
        second: TorchatBytes {
            data: std::ptr::null_mut(),
            len: 0,
        },
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_free_pair(value: TorchatPair) {
    torchat_free_bytes(value.first);
    torchat_free_bytes(value.second);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_encrypt(
    value: *mut TorchatConversation,
    data: *const u8,
    len: usize,
) -> TorchatBytes {
    protected(|| {
        if value.is_null() {
            return Err("conversation is null".into());
        }
        (*value)
            .conversation
            .encrypt(input(data, len)?)
            .map_err(|e| e.to_string())
    })
    .map(bytes)
    .unwrap_or(TorchatBytes {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_decrypt(
    value: *mut TorchatConversation,
    data: *const u8,
    len: usize,
) -> TorchatBytes {
    protected(|| {
        if value.is_null() {
            return Err("conversation is null".into());
        }
        (*value)
            .conversation
            .decrypt(input(data, len)?)
            .map_err(|e| e.to_string())
    })
    .map(bytes)
    .unwrap_or(TorchatBytes {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_conversation_snapshot(
    value: *const TorchatConversation,
) -> TorchatBytes {
    protected(|| {
        if value.is_null() {
            return Err("conversation is null".into());
        }
        (*value).conversation.snapshot()
    })
    .map(bytes)
    .unwrap_or(TorchatBytes {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn c_api_identity_and_invite_round_trip() {
        let identity = torchat_identity_generate();
        assert!(!identity.is_null());

        let fingerprint_ptr = unsafe { torchat_identity_fingerprint(identity) };
        assert!(!fingerprint_ptr.is_null());
        let fingerprint = unsafe { CStr::from_ptr(fingerprint_ptr) }.to_str().unwrap();
        assert_eq!(fingerprint.split_whitespace().count(), 8);
        unsafe { torchat_free_string(fingerprint_ptr) };

        let invite = unsafe { torchat_identity_contact_invite(identity) };
        assert!(!invite.is_null());
        let invite_bytes = unsafe { CStr::from_ptr(invite) }.to_bytes().to_vec();
        assert_eq!(
            unsafe { torchat_validate_contact_invite(invite_bytes.as_ptr(), invite_bytes.len()) },
            1
        );
        unsafe {
            torchat_free_string(invite);
            torchat_identity_free(identity);
        }
    }

    #[test]
    fn c_api_pending_invite_accepts_welcome() {
        let alice = torchat_identity_generate();
        let bob = torchat_identity_generate();
        assert!(!alice.is_null() && !bob.is_null());
        let invite_ptr = unsafe { torchat_identity_contact_invite(bob) };
        let invite = unsafe { CStr::from_ptr(invite_ptr) }.to_bytes().to_vec();
        let key_package =
            unsafe { torchat_contact_invite_key_package(invite.as_ptr(), invite.len()) };
        let alice_chat = unsafe { torchat_conversation_create(alice) };
        let pair =
            unsafe { torchat_conversation_invite(alice_chat, key_package.data, key_package.len) };
        let bob_chat = unsafe {
            torchat_conversation_accept(
                bob,
                pair.first.data,
                pair.first.len,
                pair.second.data,
                pair.second.len,
            )
        };
        assert!(!bob_chat.is_null(), "{}", unsafe {
            let error = torchat_last_error();
            if error.is_null() {
                "unknown error".into()
            } else {
                CStr::from_ptr(error).to_string_lossy().into_owned()
            }
        });
        unsafe {
            torchat_free_string(invite_ptr);
            torchat_free_bytes(key_package);
            torchat_free_pair(pair);
            torchat_conversation_free(alice_chat);
            torchat_conversation_free(bob_chat);
            torchat_identity_free(alice);
            torchat_identity_free(bob);
        }
    }
}
