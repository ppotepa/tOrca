use crate::RuntimeEvent;

#[derive(Clone, Debug, Default)]
pub struct RuntimeSession {
    selected_conversation_id: Option<String>,
    events: Vec<RuntimeEvent>,
    staged_events: Vec<RuntimeEvent>,
    bootstrap_emitted: bool,
    last_tor_status: Option<crate::RuntimeTorStatus>,
    last_runtime_error: Option<String>,
    transaction_depth: usize,
}

impl RuntimeSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn selected_conversation_id(&self) -> Option<&str> {
        self.selected_conversation_id.as_deref()
    }

    pub(crate) fn select_conversation(&mut self, conversation_id: String) {
        self.selected_conversation_id = Some(conversation_id);
    }

    pub(crate) fn clear_selected_conversation(&mut self) {
        self.selected_conversation_id = None;
    }

    pub(crate) fn begin_transaction(&mut self) {
        self.transaction_depth = self.transaction_depth.saturating_add(1);
    }

    pub(crate) fn commit_transaction(&mut self) {
        if self.transaction_depth == 0 {
            return;
        }
        self.transaction_depth -= 1;
        if self.transaction_depth == 0 && !self.staged_events.is_empty() {
            self.events.append(&mut self.staged_events);
        }
    }

    pub(crate) fn rollback_transaction(&mut self) {
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_preserves_selection_across_runtime_reconstruction() {
        let mut session = RuntimeSession::new();
        session.select_conversation("peer-1".to_owned());
        assert_eq!(session.selected_conversation_id(), Some("peer-1"));
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
