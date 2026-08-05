use crate::RuntimeEvent;

#[derive(Clone, Debug, Default)]
pub struct RuntimeSession {
    selected_conversation_id: Option<String>,
    focused_conversation_id: Option<String>,
    app_foreground: bool,
    events: Vec<RuntimeEvent>,
    staged_events: Vec<RuntimeEvent>,
    bootstrap_emitted: bool,
    last_tor_status: Option<crate::RuntimeTorStatus>,
    last_runtime_error: Option<String>,
    transaction_depth: usize,
}

impl RuntimeSession {
    pub fn new() -> Self {
        Self {
            app_foreground: true,
            ..Self::default()
        }
    }

    pub fn selected_conversation_id(&self) -> Option<&str> {
        self.selected_conversation_id.as_deref()
    }

    pub(crate) fn select_conversation(&mut self, conversation_id: String) {
        self.selected_conversation_id = Some(conversation_id);
        self.focused_conversation_id = None;
    }

    pub(crate) fn clear_selected_conversation(&mut self) {
        self.selected_conversation_id = None;
        self.focused_conversation_id = None;
    }

    pub(crate) fn set_app_foreground(&mut self, foreground: bool) {
        self.app_foreground = foreground;
        if !foreground {
            self.focused_conversation_id = None;
        }
    }

    pub(crate) fn set_conversation_focus(&mut self, conversation_id: &str, focused: bool) {
        if focused {
            self.selected_conversation_id = Some(conversation_id.to_owned());
            self.focused_conversation_id = Some(conversation_id.to_owned());
        } else if self.focused_conversation_id.as_deref() == Some(conversation_id) {
            self.focused_conversation_id = None;
        }
    }

    pub(crate) fn conversation_is_attended(&self, conversation_id: &str) -> bool {
        self.app_foreground
            && self.selected_conversation_id.as_deref() == Some(conversation_id)
            && self.focused_conversation_id.as_deref() == Some(conversation_id)
    }

    pub fn begin_transaction(&mut self) {
        self.transaction_depth = self.transaction_depth.saturating_add(1);
    }

    pub fn commit_transaction(&mut self) {
        if self.transaction_depth == 0 {
            return;
        }
        self.transaction_depth -= 1;
        if self.transaction_depth == 0 && !self.staged_events.is_empty() {
            self.events.append(&mut self.staged_events);
        }
    }

    pub fn rollback_transaction(&mut self) {
        if self.transaction_depth == 0 {
            return;
        }
        self.transaction_depth -= 1;
        if self.transaction_depth == 0 {
            self.staged_events.clear();
        }
    }

    pub(crate) fn push_event(&mut self, event: RuntimeEvent) {
        if self.transaction_depth > 0 {
            self.staged_events.push(event);
        } else {
            self.events.push(event);
        }
    }

    pub(crate) fn mark_bootstrap_emitted(&mut self) -> bool {
        if self.bootstrap_emitted {
            return false;
        }
        self.bootstrap_emitted = true;
        true
    }

    pub(crate) fn publish_tor_status(&mut self, status: crate::RuntimeTorStatus) {
        if self.last_tor_status.as_ref() == Some(&status) {
            return;
        }
        self.last_tor_status = Some(status.clone());
        if status.phase == crate::RuntimeStatusPhase::Connected {
            self.clear_runtime_error_dedup();
        }
        self.push_event(crate::runtime_status_event_from_snapshot(&status));
    }

    pub(crate) fn publish_runtime_error(&mut self, message: impl Into<String>) {
        let message = message.into();
        if self.last_runtime_error.as_deref() == Some(message.as_str()) {
            return;
        }
        self.last_runtime_error = Some(message.clone());
        self.push_event(RuntimeEvent::RuntimeError { message });
    }

    pub(crate) fn publish_runtime_log(&mut self, message: impl Into<String>) {
        let message = message.into();
        let message = message.trim();
        if message.is_empty() {
            return;
        }
        self.push_event(RuntimeEvent::RuntimeLog {
            message: message.to_owned(),
        });
    }

    pub(crate) fn clear_runtime_error_dedup(&mut self) {
        self.last_runtime_error = None;
    }

    pub fn last_tor_status(&self) -> Option<&crate::RuntimeTorStatus> {
        self.last_tor_status.as_ref()
    }

    pub fn last_runtime_error(&self) -> Option<&str> {
        self.last_runtime_error.as_deref()
    }

    pub fn drain_events(&mut self) -> Vec<RuntimeEvent> {
        self.events.drain(..).collect()
    }

    pub fn has_pending_events(&self) -> bool {
        !self.events.is_empty() || !self.staged_events.is_empty()
    }

    /// Returns whether the current transaction changed a durable projection
    /// visible to a client and the conversations whose projections changed.
    /// Transport, Tor and ephemeral presence signals deliberately do not
    /// advance the SQLite projection revision.
    pub fn pending_projection_changes(&self) -> (bool, Vec<String>) {
        let mut application = false;
        let mut conversations = std::collections::BTreeSet::new();
        for event in self.events.iter().chain(self.staged_events.iter()) {
            match event {
                RuntimeEvent::ProfileReady { .. }
                | RuntimeEvent::InviteReceived { .. }
                | RuntimeEvent::InviteStateChanged { .. }
                | RuntimeEvent::PeerEndpointChanged { .. }
                | RuntimeEvent::PeerConnectionChanged { .. }
                | RuntimeEvent::ContactCapabilityChanged { .. }
                | RuntimeEvent::Changed { .. } => application = true,
                RuntimeEvent::MessageReceived {
                    conversation_id, ..
                }
                | RuntimeEvent::MessageStateChanged {
                    conversation_id, ..
                }
                | RuntimeEvent::ConversationReadChanged {
                    conversation_id, ..
                } => {
                    application = true;
                    if let Some(conversation_id) = conversation_id {
                        conversations.insert(conversation_id.clone());
                    }
                }
                RuntimeEvent::RuntimeReady { .. }
                | RuntimeEvent::TorStatus { .. }
                | RuntimeEvent::TransportStatusChanged { .. }
                | RuntimeEvent::TypingChanged { .. }
                | RuntimeEvent::ConversationFocusChanged { .. }
                | RuntimeEvent::PresenceChanged { .. }
                | RuntimeEvent::RuntimeError { .. }
                | RuntimeEvent::RuntimeLog { .. }
                | RuntimeEvent::ProjectionChanged { .. } => {}
            }
        }
        (application, conversations.into_iter().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_preserves_selection_across_runtime_reconstruction() {
        let mut session = RuntimeSession::new();
        session.select_conversation("peer-1".to_owned());
        assert_eq!(session.selected_conversation_id(), Some("peer-1"));
        session.set_conversation_focus("peer-1", true);
        assert!(session.conversation_is_attended("peer-1"));
        session.set_app_foreground(false);
        assert!(!session.conversation_is_attended("peer-1"));
        session.clear_selected_conversation();
        assert_eq!(session.selected_conversation_id(), None);
    }

    #[test]
    fn session_owns_runtime_event_queue() {
        let mut session = RuntimeSession::new();
        session.push_event(RuntimeEvent::Changed {
            kind: Some("messages".to_owned()),
        });
        assert!(session.has_pending_events());
        assert_eq!(session.drain_events().len(), 1);
        assert!(!session.has_pending_events());
    }

    #[test]
    fn session_stages_events_until_commit() {
        let mut session = RuntimeSession::new();
        session.begin_transaction();
        session.push_event(RuntimeEvent::Changed {
            kind: Some("messages".to_owned()),
        });

        assert!(session.has_pending_events());
        assert!(session.drain_events().is_empty());

        session.commit_transaction();

        assert_eq!(session.drain_events().len(), 1);
        assert!(!session.has_pending_events());
    }

    #[test]
    fn transport_events_do_not_dirty_persistent_projections() {
        let mut session = RuntimeSession::new();
        session.begin_transaction();
        session.push_event(RuntimeEvent::TorStatus {
            phase: crate::RuntimeStatusPhase::Connected,
            label: "ready".to_owned(),
            detail: String::new(),
            progress: Some(100),
            latency_ms: None,
            retry_attempt: 0,
        });
        assert_eq!(session.pending_projection_changes(), (false, Vec::new()));
    }

    #[test]
    fn session_discards_staged_events_on_rollback() {
        let mut session = RuntimeSession::new();
        session.begin_transaction();
        session.push_event(RuntimeEvent::Changed {
            kind: Some("messages".to_owned()),
        });

        session.rollback_transaction();

        assert!(session.drain_events().is_empty());
        assert!(!session.has_pending_events());
    }
}
