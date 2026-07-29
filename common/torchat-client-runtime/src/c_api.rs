#![allow(unsafe_op_in_unsafe_fn)]
// C ABI entry points share one pointer-safety contract: callers must pass
// valid pointers/lengths and release returned ownership with the matching free
// function. The JSON dispatcher keeps business behavior inside ClientRuntime.
#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};

use crate::pairing_rules::{normalize_pairing_item, normalize_pairing_items};
use crate::{
    ChatMessage, ClientRuntime, ContactRecord, ConversationSummary, InviteCode, MessageState,
    PairingItem, RuntimeClock, RuntimeError, RuntimeIdentity, RuntimeProfile, RuntimeRequest,
    RuntimeResult, RuntimeStorage, RuntimeTorStatus, RuntimeTransport,
};
use serde::{Deserialize, Serialize};

pub struct TorchatClientRuntime {
    runtime: ClientRuntime<MemoryStorage, NoopTransport, AbiClock>,
}

#[derive(Default)]
struct MemoryStorage {
    identity: Option<RuntimeIdentity>,
    profile: Option<RuntimeProfile>,
    pairing_code: Option<InviteCode>,
    inbox: Vec<PairingItem>,
    outbox: Vec<PairingItem>,
    contacts: Vec<ContactRecord>,
    conversations: Vec<ConversationSummary>,
    messages: Vec<ChatMessage>,
}

#[derive(Default)]
struct NoopTransport {
    status: RuntimeTorStatus,
}

#[derive(Default)]
struct AbiClock;

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStateSnapshot {
    identity: Option<RuntimeIdentity>,
    profile: Option<RuntimeProfile>,
    pairing_code: Option<InviteCode>,
    pairing_inbox: Vec<PairingItem>,
    pairing_outbox: Vec<PairingItem>,
    contacts: Vec<ContactRecord>,
    conversations: Vec<ConversationSummary>,
    messages: Vec<ChatMessage>,
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

unsafe fn input<'a>(data: *const u8, len: usize) -> RuntimeResult<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err(RuntimeError::InvalidParams("null buffer".to_owned()));
    }
    Ok(std::slice::from_raw_parts(data, len))
}

unsafe fn protected<T>(operation: impl FnOnce() -> RuntimeResult<T>) -> Option<T> {
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => Some(value),
        Ok(Err(error)) => {
            set_error(error.to_string());
            None
        }
        Err(_) => {
            set_error("client runtime panicked");
            None
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn torchat_client_runtime_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow_mut()
            .take()
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_new(
    installation_id: *const u8,
    installation_id_len: usize,
    public_key: *const u8,
    public_key_len: usize,
    fingerprint: *const u8,
    fingerprint_len: usize,
    nickname: *const u8,
    nickname_len: usize,
) -> *mut TorchatClientRuntime {
    protected(|| {
        let installation_id = string_input(installation_id, installation_id_len)?;
        let public_key = string_input(public_key, public_key_len)?;
        let fingerprint = string_input(fingerprint, fingerprint_len)?;
        let nickname = string_input(nickname, nickname_len).unwrap_or_default();
        let identity = RuntimeIdentity::from_parts(installation_id, public_key, fingerprint);
        let profile = RuntimeProfile::from_identity(&identity, nickname);
        let storage = MemoryStorage {
            identity: Some(identity),
            profile: Some(profile),
            ..Default::default()
        };
        Ok(Box::into_raw(Box::new(TorchatClientRuntime {
            runtime: ClientRuntime::new(storage, NoopTransport::default(), AbiClock),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_free(value: *mut TorchatClientRuntime) {
    if !value.is_null() {
        drop(Box::from_raw(value));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_dispatch_json(
    value: *mut TorchatClientRuntime,
    request: *const u8,
    request_len: usize,
) -> *mut c_char {
    protected(|| {
        if value.is_null() {
            return Err(RuntimeError::Unavailable(
                "runtime handle is null".to_owned(),
            ));
        }
        let request = std::str::from_utf8(input(request, request_len)?)
            .map_err(|_| RuntimeError::InvalidParams("request is not UTF-8".to_owned()))?;
        let request: RuntimeRequest = serde_json::from_str(request)?;
        serde_json::to_string(&(*value).runtime.dispatch_request(request))
            .map_err(RuntimeError::from)
    })
    .map(c_string)
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_drain_events_json(
    value: *mut TorchatClientRuntime,
) -> *mut c_char {
    protected(|| {
        if value.is_null() {
            return Err(RuntimeError::Unavailable(
                "runtime handle is null".to_owned(),
            ));
        }
        serde_json::to_string(&(*value).runtime.drain_events()).map_err(RuntimeError::from)
    })
    .map(c_string)
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_import_state_json(
    value: *mut TorchatClientRuntime,
    state: *const u8,
    state_len: usize,
) -> *mut c_char {
    protected(|| {
        if value.is_null() {
            return Err(RuntimeError::Unavailable(
                "runtime handle is null".to_owned(),
            ));
        }
        let state = std::str::from_utf8(input(state, state_len)?)
            .map_err(|_| RuntimeError::InvalidParams("state is not UTF-8".to_owned()))?;
        let snapshot: RuntimeStateSnapshot = serde_json::from_str(state)?;
        (*value).runtime.storage_mut().replace(snapshot);
        serde_json::to_string(&true).map_err(RuntimeError::from)
    })
    .map(c_string)
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn torchat_client_runtime_export_state_json(
    value: *mut TorchatClientRuntime,
) -> *mut c_char {
    protected(|| {
        if value.is_null() {
            return Err(RuntimeError::Unavailable(
                "runtime handle is null".to_owned(),
            ));
        }
        serde_json::to_string(&(*value).runtime.storage().snapshot()).map_err(RuntimeError::from)
    })
    .map(c_string)
    .unwrap_or(std::ptr::null_mut())
}

unsafe fn string_input(data: *const u8, len: usize) -> RuntimeResult<String> {
    Ok(std::str::from_utf8(input(data, len)?)
        .map_err(|_| RuntimeError::InvalidParams("input is not UTF-8".to_owned()))?
        .to_owned())
}

impl MemoryStorage {
    fn replace(&mut self, snapshot: RuntimeStateSnapshot) {
        self.identity = snapshot.identity;
        self.profile = snapshot.profile;
        self.pairing_code = snapshot.pairing_code;
        self.inbox = normalize_pairing_items(snapshot.pairing_inbox);
        self.outbox = normalize_pairing_items(snapshot.pairing_outbox);
        self.contacts = snapshot.contacts;
        self.conversations = snapshot.conversations;
        self.messages = snapshot.messages;
    }

    fn snapshot(&self) -> RuntimeStateSnapshot {
        RuntimeStateSnapshot {
            identity: self.identity.clone(),
            profile: self.profile.clone(),
            pairing_code: self.pairing_code.clone(),
            pairing_inbox: self.inbox.clone(),
            pairing_outbox: self.outbox.clone(),
            contacts: self.contacts.clone(),
            conversations: self.conversations.clone(),
            messages: self.messages.clone(),
        }
    }
}

impl RuntimeStorage for MemoryStorage {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        Ok(self.identity.clone())
    }
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        Ok(self.profile.clone())
    }
    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        self.profile = Some(profile);
        Ok(())
    }
    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>> {
        Ok(self.pairing_code.clone())
    }
    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()> {
        self.pairing_code = Some(code);
        Ok(())
    }
    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(self.inbox.clone())
    }
    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        let item = normalize_pairing_item(item);
        self.inbox
            .retain(|value| value.pairing_id != item.pairing_id);
        self.inbox.push(item);
        Ok(())
    }
    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(self.outbox.clone())
    }
    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        let item = normalize_pairing_item(item);
        self.outbox
            .retain(|value| value.pairing_id != item.pairing_id);
        self.outbox.push(item);
        Ok(())
    }
    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        Ok(self.contacts.clone())
    }
    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()> {
        self.contacts
            .retain(|value| value.installation_id != contact.installation_id);
        self.contacts.push(contact);
        Ok(())
    }
    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        Ok(self.conversations.clone())
    }
    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()> {
        self.conversations
            .retain(|value| value.id != conversation.id);
        self.conversations.push(conversation);
        Ok(())
    }
    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()> {
        for conversation in &mut self.conversations {
            if conversation.id == conversation_id {
                conversation.unread_count = 0;
            }
        }
        Ok(())
    }
    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        Ok(self
            .messages
            .iter()
            .filter(|value| value.conversation_id == conversation_id)
            .cloned()
            .collect())
    }
    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()> {
        self.messages.retain(|value| value.id != message.id);
        self.messages.push(message);
        Ok(())
    }
    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
        Ok(self
            .messages
            .iter()
            .filter(|value| {
                matches!(
                    value.state,
                    MessageState::Queued | MessageState::Sending | MessageState::Sent
                )
            })
            .cloned()
            .collect())
    }
}

impl RuntimeTransport for NoopTransport {
    fn connect(&mut self) -> RuntimeResult<RuntimeTorStatus> {
        self.status.phase = crate::RuntimeStatusPhase::Connected;
        Ok(self.status.clone())
    }
    fn status(&self) -> RuntimeTorStatus {
        self.status.clone()
    }
    fn update_profile(&mut self, _nickname: &str) -> RuntimeResult<()> {
        Ok(())
    }
    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        Err(RuntimeError::Unavailable(
            "native runtime transport is not attached".to_owned(),
        ))
    }
    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        Err(RuntimeError::Unavailable(
            "native runtime transport is not attached".to_owned(),
        ))
    }
    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(Vec::new())
    }
}

impl RuntimeClock for AbiClock {
    fn now_ms(&self) -> i64 {
        crate::SystemRuntimeClock.now_ms()
    }
}

impl Default for RuntimeTorStatus {
    fn default() -> Self {
        Self {
            phase: crate::RuntimeStatusPhase::Offline,
            label: "offline".to_owned(),
            detail: String::new(),
            progress: None,
            latency_ms: None,
            retry_attempt: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn c_api_dispatches_runtime_identity_json() {
        let runtime = unsafe {
            torchat_client_runtime_new(
                b"install-1".as_ptr(),
                9,
                b"pk".as_ptr(),
                2,
                b"fp".as_ptr(),
                2,
                b"Alice".as_ptr(),
                5,
            )
        };
        assert!(!runtime.is_null());
        let request = br#"{"id":"1","method":"identity","params":{}}"#;
        let response = unsafe {
            torchat_client_runtime_dispatch_json(runtime, request.as_ptr(), request.len())
        };
        assert!(!response.is_null());
        let value = unsafe { CStr::from_ptr(response) }.to_str().unwrap();
        assert!(value.contains(r#""ok":true"#));
        assert!(value.contains(r#""installationId":"install-1""#));
        unsafe {
            torchat_client_runtime_free_string(response);
            torchat_client_runtime_free(runtime);
        }
    }

    #[test]
    fn c_api_imports_state_and_exports_runtime_changes() {
        let runtime = unsafe {
            torchat_client_runtime_new(
                b"install-1".as_ptr(),
                9,
                b"pk".as_ptr(),
                2,
                b"fp".as_ptr(),
                2,
                b"Alice".as_ptr(),
                5,
            )
        };
        assert!(!runtime.is_null());

        let state = br#"{
            "identity":{"installationId":"install-1","publicKey":"pk","fingerprint":"fp"},
            "profile":{"installationId":"install-1","nickname":"Alice","publicKey":"pk","fingerprint":"fp"},
            "pairingInbox":[],
            "pairingOutbox":[],
            "contacts":[{"installationId":"peer-1","nickname":"Peer","publicKey":"peer-pk","fingerprint":"peer-fp","verification":"UNVERIFIED"}],
            "conversations":[{"id":"peer-1","contactInstallationId":"peer-1","status":"ACTIVE","lastMessagePreview":"hello","lastMessageAt":7,"unreadCount":3}],
            "messages":[]
        }"#;
        let imported = unsafe {
            torchat_client_runtime_import_state_json(runtime, state.as_ptr(), state.len())
        };
        assert!(!imported.is_null());
        let imported_value = unsafe { CStr::from_ptr(imported) }.to_str().unwrap();
        assert_eq!(imported_value, "true");

        let request = br#"{"id":"2","method":"openConversation","params":{"id":"peer-1"}}"#;
        let response = unsafe {
            torchat_client_runtime_dispatch_json(runtime, request.as_ptr(), request.len())
        };
        assert!(!response.is_null());

        let exported = unsafe { torchat_client_runtime_export_state_json(runtime) };
        assert!(!exported.is_null());
        let value: serde_json::Value =
            serde_json::from_str(unsafe { CStr::from_ptr(exported) }.to_str().unwrap()).unwrap();
        assert_eq!(value["conversations"][0]["unreadCount"], 0);

        unsafe {
            torchat_client_runtime_free_string(imported);
            torchat_client_runtime_free_string(response);
            torchat_client_runtime_free_string(exported);
            torchat_client_runtime_free(runtime);
        }
    }

    #[test]
    fn c_api_preserves_runtime_session_across_dispatches() {
        let runtime = unsafe {
            torchat_client_runtime_new(
                b"install-1".as_ptr(),
                9,
                b"pk".as_ptr(),
                2,
                b"fp".as_ptr(),
                2,
                b"Alice".as_ptr(),
                5,
            )
        };
        assert!(!runtime.is_null());

        let state = br#"{
            "identity":{"installationId":"install-1","publicKey":"pk","fingerprint":"fp"},
            "profile":{"installationId":"install-1","nickname":"Alice","publicKey":"pk","fingerprint":"fp"},
            "pairingInbox":[],
            "pairingOutbox":[],
            "contacts":[{"installationId":"peer-1","nickname":"Peer","publicKey":"peer-pk","fingerprint":"peer-fp","verification":"UNVERIFIED"}],
            "conversations":[{"id":"peer-1","contactInstallationId":"peer-1","status":"ACTIVE","lastMessagePreview":"hello","lastMessageAt":7,"unreadCount":3}],
            "messages":[]
        }"#;
        let imported = unsafe {
            torchat_client_runtime_import_state_json(runtime, state.as_ptr(), state.len())
        };
        assert!(!imported.is_null());

        let open = br#"{"id":"2","method":"openConversation","params":{"id":"peer-1"}}"#;
        let open_response =
            unsafe { torchat_client_runtime_dispatch_json(runtime, open.as_ptr(), open.len()) };
        assert!(!open_response.is_null());
        unsafe { torchat_client_runtime_free_string(open_response) };

        let receive = br#"{"id":"3","method":"receiveMessage","params":{"id":"peer-1","text":"hi","messageId":"00000000-0000-0000-0000-000000000011"}}"#;
        let receive_response = unsafe {
            torchat_client_runtime_dispatch_json(runtime, receive.as_ptr(), receive.len())
        };
        assert!(!receive_response.is_null());
        unsafe { torchat_client_runtime_free_string(receive_response) };

        let exported = unsafe { torchat_client_runtime_export_state_json(runtime) };
        assert!(!exported.is_null());
        let value: serde_json::Value =
            serde_json::from_str(unsafe { CStr::from_ptr(exported) }.to_str().unwrap()).unwrap();
        assert_eq!(value["conversations"][0]["unreadCount"], 0);

        unsafe {
            torchat_client_runtime_free_string(imported);
            torchat_client_runtime_free_string(exported);
            torchat_client_runtime_free(runtime);
        }
    }

    #[test]
    fn c_api_conforms_to_shared_runtime_message_and_event_flow() {
        let runtime = unsafe {
            torchat_client_runtime_new(
                b"installation-alice".as_ptr(),
                18,
                b"alice-public-key".as_ptr(),
                16,
                b"alice-fingerprint".as_ptr(),
                17,
                b"Alice".as_ptr(),
                5,
            )
        };
        assert!(!runtime.is_null());

        let bootstrap = dispatch(runtime, r#"{"method":"bootstrapRuntime"}"#);
        assert_eq!(bootstrap["ok"], true);
        let bootstrap_again = dispatch(runtime, r#"{"method":"bootstrapRuntime"}"#);
        assert_eq!(bootstrap_again["result"], false);
        let events = drain(runtime);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["type"], "runtime_ready");
        assert_eq!(events[1]["type"], "profile_ready");

        import_state(
            runtime,
            r#"{
                "identity":{"installationId":"installation-alice","publicKey":"alice-public-key","fingerprint":"alice-fingerprint"},
                "profile":{"installationId":"installation-alice","nickname":"Alice","publicKey":"alice-public-key","fingerprint":"alice-fingerprint"},
                "pairingInbox":[],
                "pairingOutbox":[],
                "contacts":[{"installationId":"installation-bob","nickname":"Bob","publicKey":"bob-public-key","fingerprint":"bob-fingerprint","verification":"VERIFIED"}],
                "conversations":[{"id":"installation-bob","contactInstallationId":"installation-bob","status":"ACTIVE","lastMessagePreview":"","lastMessageAt":0,"unreadCount":0}],
                "messages":[]
            }"#,
        );

        let send = dispatch(
            runtime,
            r#"{"method":"sendMessage","params":{"id":"installation-bob","text":"hello"}}"#,
        );
        assert_eq!(send["ok"], true);
        assert_eq!(
            send["result"]["recipientInstallationId"],
            "installation-bob"
        );
        let message_id = send["result"]["messageId"].as_str().unwrap();
        let events = drain(runtime);
        assert_eq!(events[0]["state"], "QUEUED");
        assert_eq!(events[2]["state"], "SENDING");

        let forwarded = dispatch(
            runtime,
            &format!(
                r#"{{"method":"applyMessageTransportOutcome","params":{{"messageId":"{message_id}","outcome":"FORWARDED"}}}}"#
            ),
        );
        assert_eq!(forwarded["result"]["state"], "SENT");
        let delivered = dispatch(
            runtime,
            &format!(
                r#"{{"method":"applyMessageTransportOutcome","params":{{"messageId":"{message_id}","outcome":"DELIVERED"}}}}"#
            ),
        );
        assert_eq!(delivered["result"]["state"], "DELIVERED");

        let exported = export_state(runtime);
        assert_eq!(exported["messages"][0]["state"], "DELIVERED");

        unsafe {
            torchat_client_runtime_free(runtime);
        }
    }

    fn dispatch(runtime: *mut TorchatClientRuntime, request: &str) -> serde_json::Value {
        let response = unsafe {
            torchat_client_runtime_dispatch_json(runtime, request.as_ptr(), request.len())
        };
        assert!(!response.is_null());
        let value = unsafe { CStr::from_ptr(response) }.to_str().unwrap();
        let json = serde_json::from_str(value).unwrap();
        unsafe { torchat_client_runtime_free_string(response) };
        json
    }

    fn drain(runtime: *mut TorchatClientRuntime) -> Vec<serde_json::Value> {
        let events = unsafe { torchat_client_runtime_drain_events_json(runtime) };
        assert!(!events.is_null());
        let value = unsafe { CStr::from_ptr(events) }.to_str().unwrap();
        let json = serde_json::from_str(value).unwrap();
        unsafe { torchat_client_runtime_free_string(events) };
        json
    }

    fn import_state(runtime: *mut TorchatClientRuntime, state: &str) {
        let imported = unsafe {
            torchat_client_runtime_import_state_json(runtime, state.as_ptr(), state.len())
        };
        assert!(!imported.is_null());
        unsafe { torchat_client_runtime_free_string(imported) };
    }

    fn export_state(runtime: *mut TorchatClientRuntime) -> serde_json::Value {
        let exported = unsafe { torchat_client_runtime_export_state_json(runtime) };
        assert!(!exported.is_null());
        let value = unsafe { CStr::from_ptr(exported) }.to_str().unwrap();
        let json = serde_json::from_str(value).unwrap();
        unsafe { torchat_client_runtime_free_string(exported) };
        json
    }
}
