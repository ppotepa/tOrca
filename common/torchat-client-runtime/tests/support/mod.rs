use torchat_client_runtime::{
    ChatMessage, ClientRuntime, ContactRecord, ConversationSummary, InviteCode, MessageState,
    PairingItem, RuntimeClock, RuntimeIdentity, RuntimeProfile, RuntimeResult, RuntimeStatusPhase,
    RuntimeStorage, RuntimeTorStatus, RuntimeTransport,
};

#[derive(Default)]
pub struct ScenarioStorage {
    pub identity: Option<RuntimeIdentity>,
    pub profile: Option<RuntimeProfile>,
    pub pairing_code: Option<InviteCode>,
    pub inbox: Vec<PairingItem>,
    pub outbox: Vec<PairingItem>,
    pub contacts: Vec<ContactRecord>,
    pub conversations: Vec<ConversationSummary>,
    pub messages: Vec<ChatMessage>,
}

impl ScenarioStorage {
    pub fn from_state(state: &serde_json::Value) -> Self {
        let mut storage = Self {
            identity: Some(RuntimeIdentity::from_parts(
                "installation-alice".to_owned(),
                "alice-public-key".to_owned(),
                "alice-fingerprint".to_owned(),
            )),
            ..Self::default()
        };
        if let Some(profile) = state.get("profile") {
            storage.profile = Some(serde_json::from_value(profile.clone()).unwrap());
        }
        storage.contacts = parse_array(state, "contacts");
        storage.conversations = parse_array(state, "conversations");
        storage.messages = parse_array(state, "messages");
        storage.inbox = parse_array(state, "pairingInbox");
        storage.outbox = parse_array(state, "pairingOutbox");
        storage
    }
}

fn parse_array<T: serde::de::DeserializeOwned>(state: &serde_json::Value, key: &str) -> Vec<T> {
    state
        .get(key)
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]))
        .as_array()
        .expect("scenario state collection must be an array")
        .iter()
        .cloned()
        .map(|value| serde_json::from_value(value).unwrap())
        .collect()
}

impl RuntimeStorage for ScenarioStorage {
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
        self.inbox
            .retain(|value| value.pairing_id != item.pairing_id);
        self.inbox.push(item);
        Ok(())
    }

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(self.outbox.clone())
    }

    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
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
            .filter(|message| message.conversation_id == conversation_id)
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
            .filter(|message| {
                message.outgoing
                    && matches!(
                        message.state,
                        MessageState::Queued | MessageState::Sending | MessageState::Sent
                    )
            })
            .cloned()
            .collect())
    }
}

#[derive(Default)]
pub struct ScenarioTransport;

impl RuntimeTransport for ScenarioTransport {
    fn connect(&mut self) -> RuntimeResult<RuntimeTorStatus> {
        Ok(self.status())
    }

    fn status(&self) -> RuntimeTorStatus {
        RuntimeTorStatus {
            phase: RuntimeStatusPhase::Connected,
            label: "connected".to_owned(),
            detail: String::new(),
            progress: Some(100),
            latency_ms: Some(1),
            retry_attempt: 0,
        }
    }

    fn update_profile(&mut self, _nickname: &str) -> RuntimeResult<()> {
        Ok(())
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        Ok(InviteCode {
            code: "12345678".to_owned(),
            expires_at: 9999999999,
        })
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        serde_json::from_value(serde_json::json!({
            "pairingId": "pairing-submit",
            "capability": "chat",
            "expiresAt": 9999999999_i64,
            "state": "PENDING",
            "received": false,
            "availableActions": ["CANCEL"]
        }))
        .map_err(Into::into)
    }

    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(Vec::new())
    }
}

#[derive(Default)]
pub struct ScenarioClock;

impl RuntimeClock for ScenarioClock {
    fn now_ms(&self) -> i64 {
        42
    }

    fn now_secs(&self) -> i64 {
        42
    }
}

pub type ScenarioRuntime = ClientRuntime<ScenarioStorage, ScenarioTransport, ScenarioClock>;

pub fn runtime_from_state(state: &serde_json::Value) -> ScenarioRuntime {
    ClientRuntime::new(
        ScenarioStorage::from_state(state),
        ScenarioTransport,
        ScenarioClock,
    )
}
