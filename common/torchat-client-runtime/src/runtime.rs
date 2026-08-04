use crate::pairing_rules::{PairingAction, normalize_pairing_item};
use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteState, MessageSendEffect,
    MessageTransportOutcome, PairingItem, RelationshipTransition, RuntimeClock, RuntimeError,
    RuntimeEvent, RuntimeIdentity, RuntimeProfile, RuntimeResult, RuntimeSendEffect,
    RuntimeSession, RuntimeStorage, RuntimeTransport, logic::fallback_contact_nickname,
};

mod helpers;
mod lifecycle;
mod message_delivery;
mod pairing_process;
mod relationship_process;
use helpers::{parse_uuid, validate_nickname};
use pairing_process::{send_effect as pairing_send_effect, transition_invite_state};
use uuid::Uuid;

pub struct ClientRuntime<S, T, C> {
    storage: S,
    transport: T,
    clock: C,
    session: RuntimeSession,
}

impl<S, T, C> ClientRuntime<S, T, C>
where
    S: RuntimeStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    pub fn new(storage: S, transport: T, clock: C) -> Self {
        Self {
            storage,
            transport,
            clock,
            session: RuntimeSession::new(),
        }
    }

    pub fn with_session(storage: S, transport: T, clock: C, session: RuntimeSession) -> Self {
        Self {
            storage,
            transport,
            clock,
            session,
        }
    }

    pub fn into_parts(self) -> (S, T, C) {
        let (storage, transport, clock, _) = self.into_parts_with_session();
        (storage, transport, clock)
    }

    pub fn into_parts_with_session(self) -> (S, T, C, RuntimeSession) {
        (self.storage, self.transport, self.clock, self.session)
    }

    pub fn session(&self) -> &RuntimeSession {
        &self.session
    }

    pub fn session_mut(&mut self) -> &mut RuntimeSession {
        &mut self.session
    }

    pub fn restore_session(&mut self, session: RuntimeSession) {
        self.session = session;
    }

    pub fn storage(&self) -> &S {
        &self.storage
    }

    pub fn storage_mut(&mut self) -> &mut S {
        &mut self.storage
    }

    pub fn drain_events(&mut self) -> Vec<RuntimeEvent> {
        self.session.drain_events()
    }

    pub fn emit_tor_status(&mut self, status: crate::RuntimeTorStatus) {
        self.session.publish_tor_status(status);
    }

    pub fn emit_runtime_error(&mut self, message: impl Into<String>) {
        self.session.publish_runtime_error(message);
    }

    pub fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        self.storage.identity()
    }

    pub fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        self.storage.profile()
    }

    /// Compatibility helper for non-engine hosts. The production actor uses
    /// `commit_nickname` after performing the network effect outside SQLite.
    pub fn set_nickname(&mut self, nickname: String) -> RuntimeResult<RuntimeProfile> {
        let nickname = validate_nickname(nickname)?;
        self.commit_nickname(nickname)
    }

    pub fn commit_nickname(&mut self, nickname: String) -> RuntimeResult<RuntimeProfile> {
        let nickname = validate_nickname(nickname)?;
        let identity = self
            .storage
            .identity()?
            .ok_or_else(|| RuntimeError::Unavailable("runtime identity is not ready".to_owned()))?;
        let profile = RuntimeProfile::from_identity(&identity, nickname.to_owned());
        self.storage.put_profile(profile.clone())?;
        self.session.push_event(RuntimeEvent::ProfileReady {
            profile: profile.clone(),
        });
        Ok(profile)
    }

    pub fn prepare_nickname(&self, nickname: String) -> RuntimeResult<String> {
        validate_nickname(nickname)
    }

    pub fn refresh_pairing_code(&mut self) -> RuntimeResult<crate::InviteCode> {
        self.prepare_refresh_pairing_code()?;
        let code = self.transport.refresh_pairing_code()?;
        self.commit_pairing_code(code.clone())?;
        Ok(code)
    }

    pub fn prepare_refresh_pairing_code(&self) -> RuntimeResult<()> {
        self.require_pairing_profile_ready()
    }

    pub fn commit_pairing_code(&mut self, code: crate::InviteCode) -> RuntimeResult<()> {
        self.storage.put_pairing_code(code.clone())?;
        Ok(())
    }

    pub fn prepare_submit_pairing_code(&mut self, code: String) -> RuntimeResult<String> {
        let normalized = pairing_process::normalize_pairing_code(&code)?;
        let mut outbox = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut outbox, false)?;
        self.complete_outbox_pairings_for_existing_contacts()?;
        if pairing_process::has_outstanding_request(&self.storage.pairing_outbox()?) {
            return Err(RuntimeError::Conflict(
                "an active pairing request already exists".to_owned(),
            ));
        }
        Ok(normalized)
    }

    /// A locally committed contact proves that the corresponding outgoing
    /// pairing progressed beyond the point at which it can block another
    /// request. This also repairs records created before the peer outcome was
    /// persisted by the transport layer.
    fn complete_outbox_pairings_for_existing_contacts(&mut self) -> RuntimeResult<()> {
        let contact_ids = self
            .storage
            .contacts()?
            .into_iter()
            .map(|contact| contact.installation_id)
            .collect::<std::collections::BTreeSet<_>>();
        for item in self.storage.pairing_outbox()? {
            let Some(item) = pairing_process::complete_for_existing_contact(item, &contact_ids)
            else {
                continue;
            };
            self.storage.put_pairing_outbox(item.clone())?;
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(item.pairing_id),
                state: Some(crate::InviteState::Completed),
            });
        }
        Ok(())
    }

    pub fn reconcile_outbox_pairing_contact(&mut self, installation_id: &str) -> RuntimeResult<()> {
        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        for item in pairing_process::reconcile_outbox_items(
            self.storage.pairing_outbox()?,
            &contact,
            installation_id,
        ) {
            self.storage.put_pairing_outbox(item.clone())?;
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(item.pairing_id),
                state: Some(InviteState::Completed),
            });
        }
        Ok(())
    }

    pub fn submit_pairing_code(&mut self, code: String) -> RuntimeResult<PairingItem> {
        let normalized = self.prepare_submit_pairing_code(code)?;
        let item = self.transport.submit_pairing_code(&normalized)?;
        self.commit_submitted_pairing(item)
    }

    pub fn commit_submitted_pairing(&mut self, item: PairingItem) -> RuntimeResult<PairingItem> {
        let item = normalize_pairing_item(item);
        self.storage.put_pairing_outbox(item.clone())?;
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(item.pairing_id.clone()),
            state: Some(item.state),
        });
        Ok(item)
    }

    fn require_pairing_profile_ready(&self) -> RuntimeResult<()> {
        pairing_process::require_profile_ready(self.storage.profile()?.as_ref())
    }

    pub fn pairing_inbox(&mut self) -> RuntimeResult<crate::PairingSyncResult> {
        let remote = self.transport.pairing_inbox()?;
        self.merge_pairing_inbox(remote)
    }

    pub fn local_pairing_lists(&self) -> RuntimeResult<(Vec<PairingItem>, Vec<PairingItem>)> {
        Ok((
            self.storage.pairing_inbox()?,
            self.storage.pairing_outbox()?,
        ))
    }

    /// Expire locally persisted invitations even when the relay is offline.
    /// The relay removes an invitation after ACK, so local state must own the
    /// final deadline and emit the state transition independently.
    pub fn expire_pending_pairings(&mut self) -> RuntimeResult<()> {
        let mut inbox = self.storage.pairing_inbox()?;
        let mut outbox = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut inbox, true)?;
        self.expire_pairing_items(&mut outbox, false)?;
        Ok(())
    }

    pub fn merge_pairing_inbox(
        &mut self,
        remote: Vec<PairingItem>,
    ) -> RuntimeResult<crate::PairingSyncResult> {
        let mut local = self.storage.pairing_inbox()?;
        self.expire_pairing_items(&mut local, true)?;
        let mut acknowledgements = Vec::new();
        for merge in pairing_process::merge_remote_items(&mut local, remote) {
            let pairing_id = merge.item.pairing_id.clone();
            acknowledgements.push(crate::PairingAcknowledgeEffect { pairing_id });
            if merge.inserted {
                self.session.push_event(RuntimeEvent::InviteReceived {
                    pairing_id: Some(merge.item.pairing_id.clone()),
                    nickname: merge
                        .item
                        .sender
                        .as_ref()
                        .map(|sender| sender.nickname.clone()),
                });
                let item = merge.item.clone();
                self.storage.put_pairing_inbox(item.clone())?;
                continue;
            }
            if merge.changed || merge.inserted {
                self.storage.put_pairing_inbox(merge.item.clone())?;
            }
        }
        local = pairing_process::visible_items(local);
        Ok(crate::PairingSyncResult {
            items: local,
            acknowledgements,
        })
    }

    pub fn prepare_accept_pairing(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<crate::PairingPreparation> {
        let item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        pairing_process::prepare_accept(item, &self.storage.contacts()?, self.clock.now_secs())
    }

    pub fn commit_accept_pairing(
        &mut self,
        pairing_id: &str,
        offer_invite_id: String,
        offer_payload: String,
    ) -> RuntimeResult<RuntimeSendEffect> {
        let item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let previous_state = item.state;
        let (item, effect) = pairing_process::commit_accept(
            item,
            offer_invite_id,
            offer_payload,
            self.clock.now_secs(),
        )?;
        self.storage.put_pairing_inbox(item.clone())?;
        if item.state != previous_state {
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(item.state),
            });
        }
        Ok(effect)
    }

    pub fn prepare_reject_pairing(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<crate::PairingPreparation> {
        let item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let capability = item.capability.clone().ok_or_else(|| {
            RuntimeError::Conflict("pairing capability does not exist".to_owned())
        })?;
        if !item.state.is_pending() {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be prepared from its current state".to_owned(),
            ));
        }
        let (_, recipient_installation_id) =
            pairing_process::prepare_reject(item, self.clock.now_secs())?;
        Ok(crate::PairingPreparation {
            pairing_id: pairing_id.to_owned(),
            recipient_installation_id,
            capability,
        })
    }

    pub fn commit_reject_pairing(&mut self, pairing_id: &str) -> RuntimeResult<RuntimeSendEffect> {
        let item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let already_rejected = item.state == InviteState::Rejected;
        let (updated_item, recipient_installation_id) =
            pairing_process::prepare_reject(item, self.clock.now_secs())?;
        if !already_rejected {
            let item = updated_item;
            self.storage.put_pairing_inbox(item.clone())?;
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(item.state),
            });
        }
        Ok(pairing_send_effect(
            pairing_id.to_owned(),
            recipient_installation_id,
            crate::PairingSendKind::Rejection,
            None,
        ))
    }

    pub fn prepare_cancel_pairing(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<crate::PairingCancelEffect> {
        let item = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        pairing_process::prepare_cancel(&item)
    }

    pub fn confirm_pairing_cancelled(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        let item = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let Some(item) = pairing_process::confirm_cancel(item)? else {
            return Ok(());
        };
        self.storage.put_pairing_outbox(item)?;
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(pairing_id.to_owned()),
            state: Some(InviteState::Cancelled),
        });
        Ok(())
    }

    pub fn apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: crate::PairingPeerOutcome,
    ) -> RuntimeResult<()> {
        let mut item = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let next_state = pairing_process::next_state_for_peer_outcome(item.state, outcome)?;
        if item.state == next_state {
            return Ok(());
        }
        item.state = next_state;
        item = normalize_pairing_item(item);
        self.storage.put_pairing_outbox(item)?;
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(pairing_id.to_owned()),
            state: Some(next_state),
        });
        Ok(())
    }

    pub fn pairing_outbox(&mut self) -> RuntimeResult<crate::PairingSyncResult> {
        self.complete_outbox_pairings_for_existing_contacts()?;
        let mut items = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut items, false)?;
        items = pairing_process::visible_items(items);
        Ok(crate::PairingSyncResult {
            items,
            acknowledgements: Vec::new(),
        })
    }

    pub fn welcome_accepted(
        &mut self,
        contact: ContactRecord,
        open_conversation: bool,
        invite_id: Option<String>,
    ) -> RuntimeResult<crate::WelcomeAcceptedResult> {
        let mut confirm_contact = None;

        if let Some(invite_id) = invite_id {
            let item = self
                .storage
                .pairing_inbox()?
                .into_iter()
                .find(|item| item.offer_invite_id.as_deref() == Some(invite_id.as_str()))
                .ok_or_else(|| {
                    RuntimeError::NotFound("pairing request does not exist".to_owned())
                })?;
            let was_completed = item.state == InviteState::Completed;
            let (updated_item, effect) =
                pairing_process::complete_welcome(item, contact.installation_id.clone())?;
            if !was_completed {
                self.storage.put_pairing_inbox(updated_item.clone())?;
                self.session.push_event(RuntimeEvent::InviteStateChanged {
                    pairing_id: Some(updated_item.pairing_id.clone()),
                    state: Some(updated_item.state),
                });
            }
            confirm_contact = Some(effect);
        }

        let conversation = self.promote_contact_with_status(
            contact.clone(),
            crate::ConversationState::Verifying,
            open_conversation,
        )?;

        Ok(crate::WelcomeAcceptedResult {
            conversation,
            confirm_contact,
        })
    }

    pub fn merge_pairing_outbox(
        &mut self,
        remote: Vec<PairingItem>,
    ) -> RuntimeResult<crate::PairingSyncResult> {
        let mut local = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut local, false)?;
        for merge in pairing_process::merge_remote_items(&mut local, remote) {
            if merge.changed || merge.inserted {
                let state = merge.item.state;
                self.storage.put_pairing_outbox(merge.item.clone())?;
                self.session.push_event(RuntimeEvent::InviteStateChanged {
                    pairing_id: Some(merge.item.pairing_id.clone()),
                    state: Some(state),
                });
            }
        }
        local = pairing_process::visible_items(local);
        Ok(crate::PairingSyncResult {
            items: local,
            acknowledgements: Vec::new(),
        })
    }

    pub fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        self.storage.contacts()
    }

    pub fn update_contact_settings(
        &mut self,
        installation_id: &str,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
    ) -> RuntimeResult<ContactRecord> {
        let mut contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        contact.local_alias = local_alias
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if contact
            .local_alias
            .as_ref()
            .is_some_and(|value| value.chars().count() > 32)
        {
            return Err(RuntimeError::InvalidParams(
                "contact alias must not exceed 32 characters".to_owned(),
            ));
        }
        contact.muted = muted;
        contact.blocked = blocked;
        self.storage.put_contact(contact.clone())?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        Ok(contact)
    }

    pub fn set_contact_transport_policy(
        &mut self,
        installation_id: &str,
        policy: crate::ContactTransportPolicy,
    ) -> RuntimeResult<ContactRecord> {
        let mut contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        contact.transport_policy = policy;
        self.storage.put_contact(contact.clone())?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        Ok(contact)
    }

    pub fn remove_relationship(
        &mut self,
        installation_id: &str,
        preserve_history: bool,
    ) -> RuntimeResult<()> {
        relationship_process::validate_removal_identifiers(installation_id, None)?;
        let removed_at = self.clock.now_ms();
        let removal_id = uuid::Uuid::new_v4().to_string();
        let relationship_epoch = self
            .storage
            .current_relationship_epoch(installation_id)?
            .saturating_add(1);
        self.storage.remove_relationship_with_id(
            installation_id,
            removed_at,
            preserve_history,
            &removal_id,
            relationship_epoch,
        )?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("messages".to_owned()),
        });
        Ok(())
    }

    pub fn remove_relationship_with_id(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        relationship_process::validate_removal_identifiers(installation_id, Some(removal_id))?;
        self.storage
            .apply_relationship_transition(RelationshipTransition::Remove {
                installation_id: installation_id.to_owned(),
                removed_at,
                preserve_history,
                removal_id: removal_id.to_owned(),
                relationship_epoch,
            })?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("messages".to_owned()),
        });
        Ok(())
    }

    pub fn apply_remote_relationship_removal(
        &mut self,
        installation_id: &str,
        remote_removed_at: i64,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        relationship_process::validate_removal_identifiers(installation_id, Some(removal_id))?;
        self.storage
            .apply_relationship_transition(RelationshipTransition::ApplyRemoteRemoval {
                installation_id: installation_id.to_owned(),
                remote_removed_at,
                removal_id: removal_id.to_owned(),
                relationship_epoch,
            })?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(())
    }

    pub fn contact_accepts_messages(&self, installation_id: &str) -> RuntimeResult<bool> {
        Ok(!self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?
            .blocked)
    }

    pub fn contact_allows_notifications(&self, installation_id: &str) -> RuntimeResult<bool> {
        Ok(self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .is_some_and(|contact| !contact.blocked && !contact.muted))
    }

    pub fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        self.storage.conversations()
    }

    pub fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        self.storage.messages(conversation_id)
    }

    pub fn open_conversation(&mut self, conversation_id: String) -> RuntimeResult<()> {
        self.session.select_conversation(conversation_id);
        Ok(())
    }

    pub fn close_conversation(&mut self) {
        self.session.clear_selected_conversation();
    }

    pub fn set_app_foreground(&mut self, foreground: bool) {
        self.session.set_app_foreground(foreground);
    }

    pub fn set_conversation_focus(
        &mut self,
        conversation_id: &str,
        focused: bool,
    ) -> RuntimeResult<()> {
        self.session
            .set_conversation_focus(conversation_id, focused);
        if !focused || !self.session.conversation_is_attended(conversation_id) {
            return Ok(());
        }
        let unread_count = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == conversation_id)
            .map(|conversation| conversation.unread_count)
            .unwrap_or(0);
        if unread_count == 0 {
            return Ok(());
        }
        self.storage.mark_conversation_read(conversation_id)?;
        self.session
            .push_event(RuntimeEvent::ConversationReadChanged {
                conversation_id: Some(conversation_id.to_owned()),
                unread_count: Some(0),
            });
        Ok(())
    }

    pub fn verify_contact(&mut self, installation_id: &str) -> RuntimeResult<()> {
        let mut contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        contact.verification = crate::VerificationState::Verified;
        self.storage.put_contact(contact)?;
        // Verification completes the relationship, so both projections must
        // become usable atomically.  Pairing can arrive through the control
        // plane without having created a conversation row yet; waiting for
        // the first message made the contact invisible from the chat list on
        // Android and desktop.  Preserve an existing summary, but create the
        // empty conversation eagerly when it is missing.
        let existing_conversation =
            self.storage
                .conversations()?
                .into_iter()
                .find(|conversation| {
                    conversation.contact_installation_id == installation_id
                        || conversation.id == installation_id
                });
        let mut conversation = existing_conversation.unwrap_or_else(|| ConversationSummary {
            id: installation_id.to_owned(),
            contact_installation_id: installation_id.to_owned(),
            status: crate::ConversationState::Active,
            last_message_preview: "Nowa rozmowa".to_owned(),
            last_message_at: self.clock.now_ms(),
            unread_count: 0,
        });
        conversation.status = crate::ConversationState::Active;
        self.storage.put_conversation(conversation)?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(())
    }

    pub fn start_conversation(&mut self, contact_id: &str) -> RuntimeResult<bool> {
        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == contact_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        let existing = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.contact_installation_id == contact.installation_id);
        let conversation = existing.unwrap_or_else(|| ConversationSummary {
            id: contact.installation_id.clone(),
            contact_installation_id: contact.installation_id,
            status: crate::ConversationState::Active,
            last_message_preview: "Nowa rozmowa".to_owned(),
            last_message_at: self.clock.now_ms(),
            unread_count: 0,
        });
        self.storage.put_conversation(conversation)?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(true)
    }

    pub fn promote_contact(
        &mut self,
        contact: ContactRecord,
        open_conversation: bool,
    ) -> RuntimeResult<ConversationSummary> {
        let status = if contact.verification == crate::VerificationState::Verified {
            crate::ConversationState::Active
        } else {
            crate::ConversationState::Verifying
        };
        self.promote_contact_with_status(contact, status, open_conversation)
    }

    fn promote_contact_with_status(
        &mut self,
        mut contact: ContactRecord,
        status: crate::ConversationState,
        open_conversation: bool,
    ) -> RuntimeResult<ConversationSummary> {
        let existing_contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|value| value.installation_id == contact.installation_id);
        if let Some(existing) = existing_contact {
            if contact.nickname.trim().is_empty() {
                contact.nickname = existing.nickname;
            }
            if contact.public_key.trim().is_empty() {
                contact.public_key = existing.public_key;
            }
            if contact.fingerprint.trim().is_empty() {
                contact.fingerprint = existing.fingerprint;
            }
            if contact.dev.is_none() {
                contact.dev = existing.dev;
            }
        }
        if contact.nickname.trim().is_empty() {
            contact.nickname = fallback_contact_nickname(&contact.installation_id);
        }
        self.storage.put_contact(contact.clone())?;
        let existing_conversation =
            self.storage
                .conversations()?
                .into_iter()
                .find(|conversation| {
                    conversation.contact_installation_id == contact.installation_id
                        || conversation.id == contact.installation_id
                });
        let mut conversation = existing_conversation.unwrap_or_else(|| ConversationSummary {
            id: contact.installation_id.clone(),
            contact_installation_id: contact.installation_id.clone(),
            status,
            last_message_preview: "Nowa rozmowa".to_owned(),
            last_message_at: self.clock.now_ms(),
            unread_count: 0,
        });
        conversation.status = status;
        self.storage.put_conversation(conversation.clone())?;
        if open_conversation {
            self.session.select_conversation(conversation.id.clone());
        }
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(conversation)
    }

    pub fn send_message(
        &mut self,
        conversation_id: &str,
        text: String,
    ) -> RuntimeResult<MessageSendEffect> {
        self.send_message_reply(conversation_id, text, None)
    }

    pub fn send_message_reply(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
    ) -> RuntimeResult<MessageSendEffect> {
        let reply_to = reply_to_message_id
            .map(|message_id| {
                self.storage.message(message_id)?.ok_or_else(|| {
                    RuntimeError::NotFound("reply message does not exist".to_owned())
                })
            })
            .transpose()?
            .map(|message| {
                if message.conversation_id != conversation_id {
                    return Err(RuntimeError::Conflict(
                        "reply message belongs to another conversation".to_owned(),
                    ));
                }
                Ok(crate::MessageReply {
                    message_id: message.id,
                    body: message.body,
                    outgoing: message.outgoing,
                })
            })
            .transpose()?;
        let message = self.queue_outgoing_message(conversation_id, text, reply_to)?;
        self.prepare_message_send(&message.id)
    }

    pub fn retry_message(&mut self, message_id: &str) -> RuntimeResult<MessageSendEffect> {
        let mut message = self
            .storage
            .message(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message cannot be retried".to_owned(),
            ));
        }
        if !matches!(
            message.state,
            crate::MessageState::Failed | crate::MessageState::Queued
        ) {
            return Err(RuntimeError::Conflict(
                "message is not eligible for manual retry".to_owned(),
            ));
        }
        let conversation = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == message.conversation_id)
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == conversation.contact_installation_id)
            .ok_or_else(|| RuntimeError::NotFound("recipient contact does not exist".to_owned()))?;
        if contact.blocked {
            return Err(RuntimeError::Conflict("contact is blocked".to_owned()));
        }
        message.state = crate::MessageState::Queued;
        message.next_attempt_at = self.clock.now_ms();
        message.ack_deadline = None;
        message.last_transport_error = None;
        self.storage.put_message(message.clone())?;
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(parse_uuid(&message.id)?),
            conversation_id: Some(message.conversation_id.clone()),
            state: Some(crate::MessageState::Queued),
        });
        self.prepare_message_send(message_id)
    }

    pub fn delete_message_local(&mut self, message_id: &str) -> RuntimeResult<()> {
        let message = self
            .storage
            .message(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        self.storage.delete_message(message_id)?;
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some(format!("messages:{}", message.conversation_id)),
        });
        Ok(())
    }

    pub fn apply_message_read(&mut self, message_id: Uuid) -> RuntimeResult<ChatMessage> {
        let mut message = self
            .storage
            .message(&message_id.to_string())?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message cannot receive a read receipt".to_owned(),
            ));
        }
        if message.state == crate::MessageState::Read {
            return Ok(message);
        }
        if !matches!(
            message.state,
            crate::MessageState::Sent | crate::MessageState::Delivered
        ) {
            return Err(RuntimeError::Conflict(
                "message is not eligible for a read receipt".to_owned(),
            ));
        }
        message.state = crate::MessageState::Read;
        self.storage.put_message(message.clone())?;
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
            conversation_id: Some(message.conversation_id.clone()),
            state: Some(crate::MessageState::Read),
        });
        Ok(message)
    }

    fn queue_outgoing_message(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to: Option<crate::MessageReply>,
    ) -> RuntimeResult<ChatMessage> {
        let text = message_delivery::validate_message_text(&text)?;
        let existing = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == conversation_id)
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        if !existing.status.can_send() {
            return Err(RuntimeError::Conflict(
                "conversation is not ready to send".to_owned(),
            ));
        }
        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == existing.contact_installation_id)
            .ok_or_else(|| RuntimeError::NotFound("recipient contact does not exist".to_owned()))?;
        if contact.verification != crate::VerificationState::Verified {
            return Err(RuntimeError::Conflict(
                "contact must be verified before sending".to_owned(),
            ));
        }
        if contact.blocked {
            return Err(RuntimeError::Conflict("contact is blocked".to_owned()));
        }
        // UUIDv7 keeps the stable message identifier chronologically sortable
        // when several messages share the same millisecond timestamp.
        let message_id = Uuid::now_v7();
        let created_at = self.clock.now_ms();
        let message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: true,
            body: text.to_owned(),
            reply_to,
            state: crate::MessageState::Queued,
            created_at,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        };
        let conversation = crate::runtime_conversation_summary_on_outgoing(
            Some(existing.unread_count),
            existing.id,
            contact.installation_id,
            text.to_owned(),
            created_at,
        );
        self.storage.put_message(message.clone())?;
        self.storage.put_conversation(conversation)?;
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
            conversation_id: Some(message.conversation_id.clone()),
            state: Some(message.state.clone()),
        });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(message)
    }

    fn prepare_message_send(&mut self, message_id: &str) -> RuntimeResult<MessageSendEffect> {
        let mut message = self
            .storage
            .message(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;

        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message cannot be sent".to_owned(),
            ));
        }

        let conversation = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == message.conversation_id)
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;

        if !conversation.status.can_send() {
            return Err(RuntimeError::Conflict(
                "conversation is not ready to send".to_owned(),
            ));
        }

        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == conversation.contact_installation_id)
            .ok_or_else(|| RuntimeError::NotFound("recipient contact does not exist".to_owned()))?;

        if contact.verification != crate::VerificationState::Verified {
            return Err(RuntimeError::Conflict(
                "contact must be verified before sending".to_owned(),
            ));
        }
        if contact.blocked {
            return Err(RuntimeError::Conflict("contact is blocked".to_owned()));
        }

        let next_state = crate::message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;

        if next_state != message.state {
            message.state = next_state.clone();
            self.storage.put_message(message.clone())?;
            self.session.push_event(RuntimeEvent::MessageStateChanged {
                message_id: Some(parse_uuid(&message.id)?),
                conversation_id: Some(message.conversation_id.clone()),
                state: Some(next_state),
            });
        }

        Ok(MessageSendEffect {
            message_id: message.id,
            conversation_id: message.conversation_id,
            recipient_installation_id: contact.installation_id,
            body: message.body,
            reply_to: message.reply_to,
        })
    }

    pub fn prepare_pending_message_sends(&mut self) -> RuntimeResult<Vec<MessageSendEffect>> {
        let message_ids = self
            .storage
            .pending_messages()?
            .into_iter()
            .filter(|message| message.outgoing)
            .map(|message| message.id)
            .collect::<Vec<_>>();

        message_ids
            .into_iter()
            .map(|message_id| self.prepare_message_send(&message_id))
            .collect()
    }

    pub fn prepare_pending_send_effects(&mut self) -> RuntimeResult<Vec<RuntimeSendEffect>> {
        let mut effects = Vec::new();
        effects.extend(
            self.prepare_pending_message_sends()?
                .into_iter()
                .map(RuntimeSendEffect::from),
        );
        effects.extend(pairing_process::pending_send_effects(
            self.storage.pairing_inbox()?,
            self.clock.now_secs(),
        )?);
        Ok(effects)
    }

    pub fn prepare_pending_receipt_effects(
        &mut self,
    ) -> RuntimeResult<Vec<crate::ReceiptSendEffect>> {
        self.storage
            .pending_receipts()?
            .into_iter()
            .map(message_delivery::validate_receipt_effect)
            .collect()
    }

    pub fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {
        self.storage.expedite_retry_after_ready()
    }

    pub fn receive_message(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<Uuid>,
    ) -> RuntimeResult<ChatMessage> {
        self.receive_message_reply(conversation_id, body, message_id, None)
    }

    pub fn receive_message_reply(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<Uuid>,
        reply_to: Option<crate::MessageReply>,
    ) -> RuntimeResult<ChatMessage> {
        let body = body.trim();
        if body.is_empty() {
            return Err(RuntimeError::InvalidParams(
                "message body must not be empty".to_owned(),
            ));
        }
        let message_id = message_id.unwrap_or_else(Uuid::new_v4);
        if let Some(existing) = self.storage.message(&message_id.to_string())? {
            if existing.outgoing {
                return Err(RuntimeError::Conflict(
                    "incoming message id collides with outgoing message".to_owned(),
                ));
            }
            if existing.conversation_id != conversation_id || existing.body != body {
                return Err(RuntimeError::Conflict(
                    "incoming message id has different content".to_owned(),
                ));
            }
            return Ok(existing);
        }
        let existing = self
            .storage
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == conversation_id);
        let selected = self.session.conversation_is_attended(conversation_id);
        let current_unread_count = existing
            .as_ref()
            .map(|conversation| conversation.unread_count);
        let created_at = self.clock.now_ms();
        let message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: false,
            body: body.to_owned(),
            reply_to,
            state: crate::MessageState::Delivered,
            created_at,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        };
        let conversation = crate::runtime_conversation_summary_on_incoming(
            current_unread_count,
            existing
                .as_ref()
                .map(|conversation| conversation.id.clone())
                .unwrap_or_else(|| conversation_id.to_owned()),
            existing
                .as_ref()
                .map(|conversation| conversation.contact_installation_id.clone())
                .unwrap_or_else(|| conversation_id.to_owned()),
            body.to_owned(),
            created_at,
            selected,
        );
        let unread_count = conversation.unread_count;
        self.storage.put_message(message.clone())?;
        self.storage.put_conversation(conversation)?;
        self.session.push_event(RuntimeEvent::MessageReceived {
            message_id: Some(message_id),
            conversation_id: Some(conversation_id.to_owned()),
            text: Some(body.to_owned()),
        });
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
            conversation_id: Some(conversation_id.to_owned()),
            state: Some(message.state.clone()),
        });
        self.session
            .push_event(RuntimeEvent::ConversationReadChanged {
                conversation_id: Some(conversation_id.to_owned()),
                unread_count: Some(unread_count),
            });
        self.session.push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(message)
    }

    pub fn apply_message_transport_outcome(
        &mut self,
        message_id: Uuid,
        outcome: MessageTransportOutcome,
    ) -> RuntimeResult<ChatMessage> {
        let mut message = self
            .storage
            .message(&message_id.to_string())?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message state is owned by receive_message".to_owned(),
            ));
        }
        let next_state = crate::message_state_after_transport_outcome(&message.state, outcome)
            .ok_or_else(|| {
                RuntimeError::Conflict(
                    "transport outcome is invalid for the current message state".to_owned(),
                )
            })?;
        if next_state == message.state {
            return Ok(message);
        }
        message.state = next_state.clone();
        self.storage.put_message(message.clone())?;
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
            conversation_id: Some(message.conversation_id.clone()),
            state: Some(next_state),
        });
        Ok(message)
    }

    pub fn archive_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        self.ensure_pairing_transition(pairing_id, PairingAction::Archive)?;
        self.transition_pairing(pairing_id, PairingAction::Archive)
    }

    fn ensure_pairing_transition(
        &self,
        pairing_id: &str,
        action: PairingAction,
    ) -> RuntimeResult<()> {
        let found = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .chain(self.storage.pairing_outbox()?)
            .find(|item| item.pairing_id == pairing_id);
        let Some(item) = found else {
            return Err(RuntimeError::NotFound(
                "pairing request does not exist".to_owned(),
            ));
        };
        if transition_invite_state(&item.state, action).is_err() {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be transitioned from its current state".to_owned(),
            ));
        }
        Ok(())
    }

    fn transition_pairing(&mut self, pairing_id: &str, action: PairingAction) -> RuntimeResult<()> {
        let mut changed = false;
        let mut next_state = None;
        for mut item in self.storage.pairing_inbox()? {
            if item.pairing_id == pairing_id {
                let state = pairing_process::transition_invite_state(&item.state, action)?;
                item = pairing_process::transition_item(item, action)?;
                self.storage.put_pairing_inbox(item)?;
                next_state = Some(state);
                changed = true;
            }
        }
        for mut item in self.storage.pairing_outbox()? {
            if item.pairing_id == pairing_id {
                let state = pairing_process::transition_invite_state(&item.state, action)?;
                item = pairing_process::transition_item(item, action)?;
                self.storage.put_pairing_outbox(item)?;
                next_state = Some(state);
                changed = true;
            }
        }
        if !changed {
            return Err(RuntimeError::NotFound(
                "pairing request does not exist".to_owned(),
            ));
        }
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(pairing_id.to_owned()),
            state: next_state,
        });
        Ok(())
    }

    fn expire_pairing_items(
        &mut self,
        items: &mut [PairingItem],
        inbox: bool,
    ) -> RuntimeResult<()> {
        let now_secs = self.clock.now_secs();
        for item in pairing_process::expire_items(items, now_secs) {
            if inbox {
                self.storage.put_pairing_inbox(item.clone())?;
            } else {
                self.storage.put_pairing_outbox(item.clone())?;
            }
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(item.pairing_id),
                state: Some(InviteState::Expired),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MessageState, RuntimeStatusPhase, VerificationState};

    #[derive(Default)]
    struct MemoryStorage {
        identity: Option<RuntimeIdentity>,
        profile: Option<RuntimeProfile>,
        pairing_code: Option<crate::InviteCode>,
        inbox: Vec<PairingItem>,
        outbox: Vec<PairingItem>,
        contacts: Vec<crate::ContactRecord>,
        conversations: Vec<ConversationSummary>,
        messages: Vec<ChatMessage>,
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
        fn pairing_code(&self) -> RuntimeResult<Option<crate::InviteCode>> {
            Ok(self.pairing_code.clone())
        }
        fn put_pairing_code(&mut self, code: crate::InviteCode) -> RuntimeResult<()> {
            self.pairing_code = Some(code);
            Ok(())
        }
        fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
            Ok(self.inbox.clone())
        }
        fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
            upsert_pairing(&mut self.inbox, item);
            Ok(())
        }
        fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
            Ok(self.outbox.clone())
        }
        fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
            upsert_pairing(&mut self.outbox, item);
            Ok(())
        }
        fn contacts(&self) -> RuntimeResult<Vec<crate::ContactRecord>> {
            Ok(self.contacts.clone())
        }
        fn put_contact(&mut self, contact: crate::ContactRecord) -> RuntimeResult<()> {
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
        fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()> {
            self.messages.retain(|value| value.id != message_id);
            Ok(())
        }
        fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
            Ok(self
                .messages
                .iter()
                .filter(|value| value.state == MessageState::Queued)
                .cloned()
                .collect())
        }
    }

    #[derive(Default)]
    struct FakeTransport {
        remote_inbox: Vec<PairingItem>,
        submitted: Vec<String>,
    }

    impl RuntimeTransport for FakeTransport {
        fn connect(&mut self) -> RuntimeResult<crate::RuntimeTorStatus> {
            Ok(crate::RuntimeTorStatus {
                phase: RuntimeStatusPhase::Connected,
                label: "connected".to_owned(),
                detail: String::new(),
                progress: Some(100),
                latency_ms: Some(1),
                retry_attempt: 0,
            })
        }
        fn status(&self) -> crate::RuntimeTorStatus {
            crate::RuntimeTorStatus {
                phase: RuntimeStatusPhase::Connected,
                label: "connected".to_owned(),
                detail: String::new(),
                progress: Some(100),
                latency_ms: Some(1),
                retry_attempt: 0,
            }
        }
        fn refresh_pairing_code(&mut self) -> RuntimeResult<crate::InviteCode> {
            Ok(crate::InviteCode {
                code: "amber-birch-cobalt-dawn-ember-fjord".to_owned(),
                expires_at: 100,
            })
        }
        fn submit_pairing_code(&mut self, code: &str) -> RuntimeResult<PairingItem> {
            self.submitted.push(code.to_owned());
            Ok(pairing("outbox-1", InviteState::Pending))
        }
        fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
            Ok(self.remote_inbox.clone())
        }
    }

    #[derive(Default)]
    struct FakeClock;

    impl RuntimeClock for FakeClock {
        fn now_ms(&self) -> i64 {
            42
        }
    }

    fn pairing(id: &str, state: InviteState) -> PairingItem {
        PairingItem {
            pairing_id: id.to_owned(),
            sender: None,
            capability: Some("chat".to_owned()),
            expires_at: 100,
            state,
            received: false,
            available_actions: crate::pairing_available_actions(state, false),
            offer_invite_id: None,
            offer_payload: None,
        }
    }

    fn upsert_pairing(items: &mut Vec<PairingItem>, item: PairingItem) {
        items.retain(|value| value.pairing_id != item.pairing_id);
        items.push(item);
    }

    fn runtime() -> ClientRuntime<MemoryStorage, FakeTransport, FakeClock> {
        let storage = MemoryStorage {
            identity: Some(RuntimeIdentity::from_parts(
                "install-1".to_owned(),
                "pk".to_owned(),
                "fp".to_owned(),
            )),
            ..Default::default()
        };
        ClientRuntime::new(storage, FakeTransport::default(), FakeClock)
    }

    fn runtime_with_queued_message() -> ClientRuntime<MemoryStorage, FakeTransport, FakeClock> {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 2,
            })
            .unwrap();
        runtime
            .storage
            .put_message(ChatMessage {
                id: Uuid::from_u128(1).to_string(),
                conversation_id: "peer-1".to_owned(),
                outgoing: true,
                body: "hello".to_owned(),
                reply_to: None,
                state: MessageState::Queued,
                created_at: 10,
                attempt_count: 0,
                last_attempt_at: None,
                next_attempt_at: 0,
                ack_deadline: None,
                last_transport_error: None,
            })
            .unwrap();
        runtime
    }

    fn runtime_with_sending_message() -> ClientRuntime<MemoryStorage, FakeTransport, FakeClock> {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 2,
            })
            .unwrap();
        runtime
            .storage
            .put_message(ChatMessage {
                id: Uuid::from_u128(1).to_string(),
                conversation_id: "peer-1".to_owned(),
                outgoing: true,
                body: "hello".to_owned(),
                reply_to: None,
                state: MessageState::Sending,
                created_at: 10,
                attempt_count: 0,
                last_attempt_at: None,
                next_attempt_at: 0,
                ack_deadline: None,
                last_transport_error: None,
            })
            .unwrap();
        runtime
    }

    fn contact() -> crate::ContactRecord {
        crate::ContactRecord {
            installation_id: "peer-1".to_owned(),
            nickname: "Peer".to_owned(),
            public_key: "pk".to_owned(),
            fingerprint: "fp".to_owned(),
            local_alias: None,
            muted: false,
            blocked: false,
            peer_endpoint_status: crate::PeerEndpointStatus::Missing,
            peer_connection_status: crate::PeerConnectionStatus::Offline,
            last_peer_connected_at: None,
            last_seen_at: None,
            verification: VerificationState::Verified,
            transport_policy: Default::default(),
            dev: None,
        }
    }

    #[test]
    fn bootstrap_runtime_emits_ready_once_then_existing_profile() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_profile(RuntimeProfile::from_parts(
                "install-1".to_owned(),
                "Alice".to_owned(),
                "pk".to_owned(),
                "fp".to_owned(),
            ))
            .unwrap();

        assert!(runtime.bootstrap_runtime().unwrap());
        assert!(!runtime.bootstrap_runtime().unwrap());

        let events = runtime.drain_events();
        assert!(matches!(events[0], RuntimeEvent::RuntimeReady { .. }));
        assert!(matches!(events[1], RuntimeEvent::ProfileReady { .. }));
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn observation_events_are_deduplicated_by_runtime_session() {
        let mut runtime = runtime();
        let status = crate::RuntimeTorStatus {
            phase: RuntimeStatusPhase::Connecting,
            label: "connecting".to_owned(),
            detail: "connecting".to_owned(),
            progress: Some(80),
            latency_ms: None,
            retry_attempt: 0,
        };

        runtime.report_tor_status(status.clone());
        runtime.report_tor_status(status);
        runtime.report_runtime_error("relay down".to_owned());
        runtime.report_runtime_error("relay down".to_owned());
        runtime.report_runtime_log("  ".to_owned());
        runtime.report_runtime_log("started".to_owned());

        let events = runtime.drain_events();
        assert_eq!(events.len(), 3);
        assert!(matches!(events[0], RuntimeEvent::TorStatus { .. }));
        assert!(matches!(events[1], RuntimeEvent::RuntimeError { .. }));
        assert!(matches!(events[2], RuntimeEvent::RuntimeLog { .. }));
    }

    #[test]
    fn connected_status_resets_runtime_error_dedup() {
        let mut runtime = runtime();

        runtime.report_runtime_error("relay down".to_owned());
        runtime.report_tor_status(crate::RuntimeTorStatus {
            phase: RuntimeStatusPhase::Connected,
            label: "connected".to_owned(),
            detail: "connected".to_owned(),
            progress: Some(100),
            latency_ms: None,
            retry_attempt: 0,
        });
        runtime.report_runtime_error("relay down".to_owned());

        let errors = runtime
            .drain_events()
            .into_iter()
            .filter(|event| matches!(event, RuntimeEvent::RuntimeError { .. }))
            .count();
        assert_eq!(errors, 2);
    }

    #[test]
    fn set_nickname_persists_profile_and_emits_event() {
        let mut runtime = runtime();
        let profile = runtime.set_nickname("Alice".to_owned()).unwrap();

        assert_eq!(profile.nickname, "Alice");
        assert!(matches!(
            runtime.drain_events().as_slice(),
            [RuntimeEvent::ProfileReady { .. }]
        ));
    }

    #[test]
    fn adapters_enqueue_status_and_error_events_through_runtime() {
        let mut runtime = runtime();
        runtime.emit_tor_status(crate::RuntimeTorStatus {
            phase: RuntimeStatusPhase::Reconnecting,
            label: "retry".to_owned(),
            detail: "relay unavailable".to_owned(),
            progress: Some(70),
            latency_ms: None,
            retry_attempt: 2,
        });
        runtime.emit_runtime_error("relay unavailable");

        assert!(matches!(
            runtime.drain_events().as_slice(),
            [
                RuntimeEvent::TorStatus {
                    phase: RuntimeStatusPhase::Reconnecting,
                    retry_attempt: 2,
                    ..
                },
                RuntimeEvent::RuntimeError { message }
            ] if message == "relay unavailable"
        ));
    }

    #[test]
    fn submit_pairing_code_normalizes_digits_and_deduplicates_active_outbox() {
        let mut runtime = runtime();
        let item = runtime
            .submit_pairing_code("amber-birch-cobalt-dawn-ember-fjord".to_owned())
            .unwrap();
        assert_eq!(item.pairing_id, "outbox-1");

        let error = runtime
            .submit_pairing_code("amber-birch-cobalt-dawn-ember-fjord".to_owned())
            .unwrap_err();
        assert!(matches!(error, RuntimeError::Conflict(_)));
    }

    #[test]
    fn submit_pairing_code_ignores_expired_outbox_item() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_outbox(PairingItem {
                pairing_id: "expired-outbox".to_owned(),
                sender: None,
                capability: None,
                expires_at: -1,
                state: InviteState::Pending,
                received: false,
                available_actions: crate::pairing_available_actions(InviteState::Pending, false),
                offer_invite_id: None,
                offer_payload: None,
            })
            .unwrap();

        let item = runtime
            .submit_pairing_code("amber-birch-cobalt-dawn-ember-fjord".to_owned())
            .unwrap();

        assert_eq!(item.pairing_id, "outbox-1");
        let expired = runtime
            .storage
            .pairing_outbox()
            .unwrap()
            .into_iter()
            .find(|value| value.pairing_id == "expired-outbox")
            .expect("expired pairing must remain stored");
        assert_eq!(expired.state, InviteState::Expired);
    }

    #[test]
    fn submitting_a_new_code_repairs_an_outbox_pairing_for_an_existing_contact() {
        let mut runtime = runtime();
        let mut stale = pairing("stale-pairing", InviteState::Pending);
        stale.sender = Some(contact());
        runtime.storage.put_contact(contact()).unwrap();
        runtime.storage.put_pairing_outbox(stale).unwrap();

        assert_eq!(
            runtime
                .prepare_submit_pairing_code(
                    "amber-birch-cobalt-dawn-ember-fjord".to_owned(),
                )
                .unwrap(),
            "amber-birch-cobalt-dawn-ember-fjord"
        );
        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Completed
        );
    }

    #[test]
    fn reading_pairing_outbox_repairs_an_outbox_pairing_for_an_existing_contact() {
        let mut runtime = runtime();
        let mut stale = pairing("stale-pairing", InviteState::Accepted);
        stale.sender = Some(contact());
        runtime.storage.put_contact(contact()).unwrap();
        runtime.storage.put_pairing_outbox(stale).unwrap();

        let items = runtime.pairing_outbox().unwrap().items;

        assert_eq!(items[0].state, InviteState::Completed);
        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Completed
        );
    }

    #[test]
    fn reconciling_outbox_pairing_contact_completes_single_unbound_request() {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Accepted))
            .unwrap();

        runtime.reconcile_outbox_pairing_contact("peer-1").unwrap();

        let repaired = runtime.storage.pairing_outbox().unwrap()[0].clone();
        assert_eq!(repaired.state, InviteState::Completed);
        assert_eq!(
            repaired
                .sender
                .as_ref()
                .map(|value| value.installation_id.as_str()),
            Some("peer-1")
        );
    }

    #[test]
    fn reconciling_outbox_pairing_contact_does_not_guess_when_multiple_requests_exist() {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Pending))
            .unwrap();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-2", InviteState::Accepted))
            .unwrap();

        runtime.reconcile_outbox_pairing_contact("peer-1").unwrap();

        let states = runtime
            .storage
            .pairing_outbox()
            .unwrap()
            .into_iter()
            .map(|item| item.state)
            .collect::<Vec<_>>();
        assert_eq!(states, vec![InviteState::Pending, InviteState::Accepted]);
    }

    #[test]
    fn refresh_pairing_code_requires_nickname() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_profile(RuntimeProfile::from_parts(
                "install-1".to_owned(),
                String::new(),
                "pk".to_owned(),
                "fp".to_owned(),
            ))
            .unwrap();
        let error = runtime.refresh_pairing_code().unwrap_err();
        assert!(matches!(error, RuntimeError::Conflict(_)));

        runtime.set_nickname("Alice".to_owned()).unwrap();
        let code = runtime.refresh_pairing_code().unwrap();
        assert_eq!(code.code, "amber-birch-cobalt-dawn-ember-fjord");
    }

    #[test]
    fn pairing_lists_hide_archived_items() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_inbox(pairing("inbox-1", InviteState::Archived))
            .unwrap();
        runtime
            .storage
            .put_pairing_inbox(pairing("inbox-2", InviteState::Rejected))
            .unwrap();
        runtime
            .storage
            .put_pairing_outbox(pairing("outbox-1", InviteState::Archived))
            .unwrap();
        runtime
            .storage
            .put_pairing_outbox(pairing("outbox-2", InviteState::Cancelled))
            .unwrap();

        assert_eq!(
            runtime.pairing_inbox().unwrap().items[0].pairing_id,
            "inbox-2"
        );
        assert_eq!(
            runtime.pairing_outbox().unwrap().items[0].pairing_id,
            "outbox-2"
        );
    }

    #[test]
    fn merge_pairing_inbox_persists_new_remote_invite() {
        let mut runtime = runtime();
        let remote = pairing("pairing-1", InviteState::Pending);

        let result = runtime.merge_pairing_inbox(vec![remote]).unwrap();

        assert_eq!(result.items.len(), 1);
        assert_eq!(result.acknowledgements.len(), 1);
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].pairing_id,
            "pairing-1"
        );
        assert!(runtime.drain_events().into_iter().any(|event| {
            matches!(event, RuntimeEvent::InviteReceived { pairing_id, .. }
                if pairing_id.as_deref() == Some("pairing-1"))
        }));
    }

    #[test]
    fn merge_pairing_inbox_retries_ack_for_existing_remote_invite() {
        let mut runtime = runtime();
        let mut local = pairing("pairing-1", InviteState::Pending);
        local.sender = Some(contact());
        local.received = true;
        runtime.storage.put_pairing_inbox(local).unwrap();

        let mut remote = pairing("pairing-1", InviteState::Pending);
        remote.sender = Some(contact());
        remote.received = true;

        let result = runtime.merge_pairing_inbox(vec![remote]).unwrap();

        assert_eq!(result.items.len(), 1);
        assert_eq!(result.acknowledgements.len(), 1);
        assert_eq!(result.acknowledgements[0].pairing_id, "pairing-1");
        assert!(!runtime.drain_events().into_iter().any(|event| matches!(
            event,
            RuntimeEvent::InviteReceived { pairing_id, .. }
                if pairing_id.as_deref() == Some("pairing-1")
        )));
    }

    #[test]
    fn focused_conversation_marks_unread_as_read() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "hello".to_owned(),
                last_message_at: 10,
                unread_count: 3,
            })
            .unwrap();

        runtime.open_conversation("peer-1".to_owned()).unwrap();
        runtime.set_conversation_focus("peer-1", true).unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 0);
    }

    #[test]
    fn verify_contact_promotes_local_record() {
        let mut runtime = runtime();
        let mut contact = contact();
        contact.verification = VerificationState::Unverified;
        runtime.storage.put_contact(contact).unwrap();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Verifying,
                last_message_preview: "verify".to_owned(),
                last_message_at: 10,
                unread_count: 0,
            })
            .unwrap();

        runtime.verify_contact("peer-1").unwrap();

        assert_eq!(
            runtime.contacts().unwrap()[0].verification,
            VerificationState::Verified
        );
        assert_eq!(
            runtime.conversations().unwrap()[0].status,
            crate::ConversationState::Active
        );
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::Changed { kind } if kind.as_deref() == Some("conversations")
        )));
    }

    #[test]
    fn verify_contact_creates_empty_conversation_when_missing() {
        let mut runtime = runtime();
        let mut contact = contact();
        contact.verification = VerificationState::Unverified;
        runtime.storage.put_contact(contact).unwrap();

        runtime.verify_contact("peer-1").unwrap();

        let conversations = runtime.conversations().unwrap();
        assert_eq!(conversations.len(), 1);
        assert_eq!(conversations[0].id, "peer-1");
        assert_eq!(conversations[0].contact_installation_id, "peer-1");
        assert_eq!(conversations[0].status, crate::ConversationState::Active);
        assert_eq!(conversations[0].last_message_preview, "Nowa rozmowa");
    }

    #[test]
    fn accept_pairing_returns_offer_effect_without_promoting_contact() {
        let mut runtime = runtime();
        let mut pairing = pairing("pairing-1", InviteState::Pending);
        pairing.sender = Some(contact());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        let _preparation = runtime.prepare_accept_pairing("pairing-1").unwrap();
        let effect = runtime
            .commit_accept_pairing(
                "pairing-1",
                "invite-1".to_owned(),
                "payload-json".to_owned(),
            )
            .unwrap();

        let pairing = effect.pairing().expect("pairing effect");
        assert_eq!(pairing.recipient_installation_id, "peer-1");
        assert_eq!(pairing.kind, crate::PairingSendKind::Offer);
        assert_eq!(pairing.payload.as_deref(), Some("payload-json"));
        assert!(runtime.contacts().unwrap().is_empty());
        assert!(runtime.conversations().unwrap().is_empty());
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Accepted
        );
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::InviteStateChanged { state, .. } if *state == Some(InviteState::Accepted)
        )));
    }

    #[test]
    fn accept_pairing_rejects_an_existing_contact() {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        let mut pairing = pairing("pairing-1", InviteState::Pending);
        pairing.sender = Some(contact());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        let error = runtime.prepare_accept_pairing("pairing-1").unwrap_err();

        assert!(error.to_string().contains("contact already exists"));
    }

    #[test]
    fn accept_pairing_prepared_persists_offer_artifacts() {
        let mut runtime = runtime();
        let mut pairing = pairing("pairing-1", InviteState::Pending);
        pairing.sender = Some(contact());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        runtime
            .commit_accept_pairing(
                "pairing-1",
                "invite-1".to_owned(),
                "payload-json".to_owned(),
            )
            .unwrap();

        let pairing = runtime.storage.pairing_inbox().unwrap().remove(0);
        assert_eq!(pairing.state, InviteState::Accepted);
        assert_eq!(pairing.offer_invite_id.as_deref(), Some("invite-1"));
        assert_eq!(pairing.offer_payload.as_deref(), Some("payload-json"));
        assert!(runtime.contacts().unwrap().is_empty());
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::InviteStateChanged { state, .. } if *state == Some(InviteState::Accepted)
        )));
    }

    #[test]
    fn complete_pairing_transitions_accepted_invite() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Accepted))
            .unwrap();

        runtime
            .apply_pairing_peer_outcome("pairing-1", crate::PairingPeerOutcome::WelcomePrepared)
            .unwrap();
        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Completed
        );
    }

    #[test]
    fn completed_pairing_ignores_late_rejection_outcome() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Completed))
            .unwrap();

        runtime
            .apply_pairing_peer_outcome("pairing-1", crate::PairingPeerOutcome::RejectionReceived)
            .unwrap();

        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Completed
        );
        assert!(!runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::InviteStateChanged { pairing_id, .. }
                if pairing_id.as_deref() == Some("pairing-1")
        )));
    }

    #[test]
    fn welcome_accepted_promotes_contact_and_completes_matching_inbox_offer() {
        let mut runtime = runtime();
        let mut pairing = pairing("pairing-1", InviteState::Accepted);
        pairing.sender = Some(contact());
        pairing.offer_invite_id = Some("invite-1".to_owned());
        pairing.offer_payload = Some("payload-json".to_owned());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        let result = runtime
            .welcome_accepted(contact(), true, Some("invite-1".to_owned()))
            .unwrap();

        assert_eq!(
            result.conversation.status,
            crate::ConversationState::Verifying
        );
        assert_eq!(result.confirm_contact.unwrap().pairing_id, "pairing-1");
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Completed
        );
    }

    #[test]
    fn welcome_accepted_without_matching_inbox_still_promotes_contact() {
        let mut runtime = runtime();

        let result = runtime.welcome_accepted(contact(), true, None).unwrap();

        assert_eq!(
            result.conversation.status,
            crate::ConversationState::Verifying
        );
        assert!(result.confirm_contact.is_none());
        assert_eq!(runtime.contacts().unwrap()[0].installation_id, "peer-1");
    }

    #[test]
    fn merge_pairing_outbox_keeps_local_completed_over_older_remote_state() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Completed))
            .unwrap();

        let result = runtime
            .merge_pairing_outbox(vec![pairing("pairing-1", InviteState::Accepted)])
            .unwrap();

        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].state, InviteState::Completed);
        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Completed
        );
    }

    #[test]
    fn welcome_accepted_requires_pairing_capability_before_promoting_contact() {
        let mut runtime = runtime();
        let mut pairing = pairing("pairing-1", InviteState::Accepted);
        pairing.sender = Some(contact());
        pairing.capability = None;
        pairing.offer_invite_id = Some("invite-1".to_owned());
        pairing.offer_payload = Some("payload-json".to_owned());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        let error = runtime
            .welcome_accepted(contact(), true, Some("invite-1".to_owned()))
            .unwrap_err();

        assert!(matches!(error, RuntimeError::Conflict(_)));
        assert!(runtime.contacts().unwrap().is_empty());
        assert!(runtime.conversations().unwrap().is_empty());
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Accepted
        );
    }

    #[test]
    fn welcome_accepted_does_not_promote_contact_for_unknown_invite() {
        let mut runtime = runtime();
        let mut pairing = pairing("pairing-1", InviteState::Accepted);
        pairing.sender = Some(contact());
        pairing.offer_invite_id = Some("invite-1".to_owned());
        pairing.offer_payload = Some("payload-json".to_owned());
        runtime.storage.put_pairing_inbox(pairing).unwrap();

        let error = runtime
            .welcome_accepted(contact(), true, Some("invite-2".to_owned()))
            .unwrap_err();

        assert!(matches!(error, RuntimeError::NotFound(_)));
        assert!(runtime.contacts().unwrap().is_empty());
        assert!(runtime.conversations().unwrap().is_empty());
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Accepted
        );
    }

    #[test]
    fn promote_contact_uses_installation_id_as_empty_nickname_fallback() {
        let mut runtime = runtime();
        let mut contact = contact();
        contact.nickname.clear();

        let conversation = runtime.promote_contact(contact, true).unwrap();

        assert_eq!(runtime.contacts().unwrap()[0].nickname, "peer-1");
        assert_eq!(conversation.id, "peer-1");
        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();
        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 1);
    }

    #[test]
    fn promote_contact_preserves_existing_conversation_summary() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Offline,
                last_message_preview: "old".to_owned(),
                last_message_at: 7,
                unread_count: 3,
            })
            .unwrap();

        let conversation = runtime.promote_contact(contact(), false).unwrap();

        assert_eq!(conversation.last_message_preview, "old");
        assert_eq!(conversation.unread_count, 3);
        assert_eq!(runtime.conversations().unwrap().len(), 1);
    }

    #[test]
    fn welcome_accepted_promotes_contact_to_verifying_conversation() {
        let mut runtime = runtime();
        let mut contact = contact();
        contact.verification = VerificationState::Unverified;

        let conversation = runtime.promote_contact(contact, true).unwrap();

        assert_eq!(
            runtime.contacts().unwrap()[0].verification,
            VerificationState::Unverified
        );
        assert_eq!(conversation.status, crate::ConversationState::Verifying);
        assert_eq!(conversation.unread_count, 0);
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::Changed { kind } if kind.as_deref() == Some("conversations")
        )));
    }

    #[test]
    fn start_conversation_emits_conversation_change() {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();

        assert!(runtime.start_conversation("peer-1").unwrap());

        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::Changed { kind } if kind.as_deref() == Some("conversations")
        )));
    }

    #[test]
    fn archive_pairing_rejects_pending_invites() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_inbox(pairing("pairing-1", InviteState::Pending))
            .unwrap();

        let error = runtime.archive_pairing("pairing-1").unwrap_err();

        assert!(matches!(error, RuntimeError::Conflict(_)));
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Pending
        );
    }

    #[test]
    fn pairing_inbox_expires_pending_items_on_read() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_inbox(pairing("pairing-1", InviteState::Pending))
            .unwrap();
        runtime.storage.inbox[0].expires_at = -1;

        let items = runtime.pairing_inbox().unwrap();

        assert_eq!(items.items[0].state, InviteState::Expired);
        assert_eq!(
            runtime.storage.pairing_inbox().unwrap()[0].state,
            InviteState::Expired
        );
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::InviteStateChanged { state, .. } if *state == Some(InviteState::Expired)
        )));
    }

    #[test]
    fn pairing_outbox_expires_pending_items_on_read() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_pairing_outbox(pairing("pairing-1", InviteState::Pending))
            .unwrap();
        runtime.storage.outbox[0].expires_at = -1;

        let items = runtime.pairing_outbox().unwrap();

        assert_eq!(items.items[0].state, InviteState::Expired);
        assert_eq!(
            runtime.storage.pairing_outbox().unwrap()[0].state,
            InviteState::Expired
        );
    }

    #[test]
    fn send_message_returns_effect_and_emits_queued_then_sending() {
        let mut runtime = runtime();
        runtime.storage.put_contact(contact()).unwrap();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 2,
            })
            .unwrap();

        let effect = runtime
            .send_message("peer-1", " hello ".to_owned())
            .unwrap();

        assert_eq!(effect.conversation_id, "peer-1");
        assert_eq!(effect.recipient_installation_id, "peer-1");
        assert_eq!(effect.body, "hello");

        let messages = runtime.messages("peer-1").unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].id, effect.message_id);
        assert_eq!(messages[0].state, MessageState::Sending);

        let conversations = runtime.conversations().unwrap();
        assert_eq!(conversations[0].last_message_preview, "hello");
        assert_eq!(conversations[0].last_message_at, 42);
        assert_eq!(conversations[0].unread_count, 2);

        let events = runtime.drain_events();
        let states = events
            .iter()
            .filter_map(|event| match event {
                RuntimeEvent::MessageStateChanged { state, .. } => state.clone(),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(states, vec![MessageState::Queued, MessageState::Sending]);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::Changed { kind } if kind.as_deref() == Some("conversations")
        )));
    }

    #[test]
    fn retry_failed_message_prepares_a_new_send_attempt() {
        let mut runtime = runtime_with_sending_message();
        let message = &mut runtime.storage.messages[0];
        message.state = MessageState::Failed;
        message.last_transport_error = Some("offline".to_owned());
        message.next_attempt_at = 500;

        let effect = runtime
            .retry_message(&Uuid::from_u128(1).to_string())
            .unwrap();

        assert_eq!(effect.body, "hello");
        let message = &runtime.storage.messages[0];
        assert_eq!(message.state, MessageState::Sending);
        assert_eq!(message.last_transport_error, None);
        assert_eq!(message.next_attempt_at, 42);
    }

    #[test]
    fn send_reply_snapshots_the_referenced_message() {
        let mut runtime = runtime_with_sending_message();
        runtime.storage.messages[0].outgoing = false;
        runtime.storage.messages[0].state = MessageState::Delivered;

        let effect = runtime
            .send_message_reply(
                "peer-1",
                "answer".to_owned(),
                Some(&Uuid::from_u128(1).to_string()),
            )
            .unwrap();

        let reply = effect.reply_to.expect("reply snapshot");
        assert_eq!(reply.message_id, Uuid::from_u128(1).to_string());
        assert_eq!(reply.body, "hello");
        assert!(!reply.outgoing);
    }

    #[test]
    fn read_receipt_advances_only_outgoing_delivered_message() {
        let mut runtime = runtime_with_sending_message();
        runtime.storage.messages[0].state = MessageState::Delivered;

        let message = runtime.apply_message_read(Uuid::from_u128(1)).unwrap();

        assert_eq!(message.state, MessageState::Read);
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::MessageStateChanged { state, .. }
                if *state == Some(MessageState::Read)
        )));
    }

    #[test]
    fn duplicate_read_receipt_is_idempotent() {
        let mut runtime = runtime_with_sending_message();
        runtime.storage.messages[0].state = MessageState::Delivered;

        let first = runtime.apply_message_read(Uuid::from_u128(1)).unwrap();
        let second = runtime.apply_message_read(Uuid::from_u128(1)).unwrap();

        assert_eq!(first.state, MessageState::Read);
        assert_eq!(second.state, MessageState::Read);
        assert_eq!(
            runtime
                .drain_events()
                .iter()
                .filter(|event| matches!(
                    event,
                    RuntimeEvent::MessageStateChanged { state, .. }
                        if *state == Some(MessageState::Read)
                ))
                .count(),
            1
        );
    }

    #[test]
    fn blocked_contact_rejects_new_and_retried_messages() {
        let mut runtime = runtime_with_sending_message();
        let updated = runtime
            .update_contact_settings("peer-1", Some("Local Peer".to_owned()), true, true)
            .unwrap();
        assert_eq!(updated.local_alias.as_deref(), Some("Local Peer"));
        assert!(updated.muted);
        assert!(updated.blocked);

        let error = runtime
            .send_message("peer-1", "blocked".to_owned())
            .unwrap_err();
        assert!(matches!(error, RuntimeError::Conflict(_)));

        runtime.storage.messages[0].state = MessageState::Failed;
        let error = runtime
            .retry_message(&Uuid::from_u128(1).to_string())
            .unwrap_err();
        assert!(matches!(error, RuntimeError::Conflict(_)));
    }

    #[test]
    fn retry_rejects_an_incoming_message() {
        let mut runtime = runtime_with_sending_message();
        runtime.storage.messages[0].outgoing = false;
        runtime.storage.messages[0].state = MessageState::Failed;

        let error = runtime
            .retry_message(&Uuid::from_u128(1).to_string())
            .unwrap_err();

        assert!(matches!(error, RuntimeError::Conflict(_)));
    }

    #[test]
    fn delete_message_local_removes_only_local_record_and_emits_refresh() {
        let mut runtime = runtime_with_sending_message();

        runtime
            .delete_message_local(&Uuid::from_u128(1).to_string())
            .unwrap();

        assert!(runtime.storage.messages.is_empty());
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::Changed { kind } if kind.as_deref() == Some("messages:peer-1")
        )));
    }

    #[test]
    fn forwarded_outcome_moves_sending_to_sent() {
        let mut runtime = runtime_with_sending_message();

        let message = runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::PeerPersisted)
            .unwrap();

        assert_eq!(message.state, MessageState::Sent);
    }

    #[test]
    fn retryable_failure_can_requeue_sent_message() {
        let mut runtime = runtime_with_sending_message();
        runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::PeerPersisted)
            .unwrap();

        let message = runtime
            .apply_message_transport_outcome(
                Uuid::from_u128(1),
                MessageTransportOutcome::RetryableFailure,
            )
            .unwrap();

        assert_eq!(message.state, MessageState::Queued);
    }

    #[test]
    fn delivered_message_stays_delivered_for_retryable_failure() {
        let mut runtime = runtime_with_sending_message();
        runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::PeerPersisted)
            .unwrap();
        runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Delivered)
            .unwrap();

        let error = runtime
            .apply_message_transport_outcome(
                Uuid::from_u128(1),
                MessageTransportOutcome::RetryableFailure,
            )
            .unwrap_err();

        assert!(matches!(error, RuntimeError::Conflict(_)));
        assert_eq!(
            runtime.messages("peer-1").unwrap()[0].state,
            MessageState::Delivered
        );
    }

    #[test]
    fn receive_message_persists_incoming_and_increments_unread_for_closed_conversation() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();
        let message_id = Uuid::from_u128(1);

        let message = runtime
            .receive_message("peer-1", " hello ".to_owned(), Some(message_id))
            .unwrap();

        assert_eq!(message.id, message_id.to_string());
        assert_eq!(message.body, "hello");
        assert_eq!(message.state, MessageState::Delivered);
        assert_eq!(runtime.messages("peer-1").unwrap()[0], message);
        let conversation = runtime.conversations().unwrap().remove(0);
        assert_eq!(conversation.last_message_preview, "hello");
        assert_eq!(conversation.unread_count, 5);
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::MessageReceived { text, .. } if text.as_deref() == Some("hello")
        )));
    }

    #[test]
    fn receive_message_is_idempotent_for_duplicate_payload() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();
        let message_id = Uuid::from_u128(2);

        let first = runtime
            .receive_message("peer-1", "hello".to_owned(), Some(message_id))
            .unwrap();
        let event_count = runtime.drain_events().len();
        let unread_after_first = runtime.conversations().unwrap()[0].unread_count;

        let second = runtime
            .receive_message("peer-1", "hello".to_owned(), Some(message_id))
            .unwrap();

        assert_eq!(first, second);
        assert_eq!(runtime.messages("peer-1").unwrap().len(), 1);
        assert_eq!(
            runtime.conversations().unwrap()[0].unread_count,
            unread_after_first
        );
        assert_eq!(runtime.drain_events().len(), 0);
        assert!(event_count > 0);
    }

    #[test]
    fn receive_message_rejects_conflicting_duplicate_message_id() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();
        let message_id = Uuid::from_u128(3);

        runtime
            .receive_message("peer-1", "hello".to_owned(), Some(message_id))
            .unwrap();
        let error = runtime
            .receive_message("peer-1", "different".to_owned(), Some(message_id))
            .unwrap_err();

        assert!(matches!(error, RuntimeError::Conflict(_)));
    }

    #[test]
    fn receive_message_keeps_open_conversation_read() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();
        runtime.open_conversation("peer-1".to_owned()).unwrap();
        runtime.set_conversation_focus("peer-1", true).unwrap();
        runtime.drain_events();

        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 0);
        assert!(runtime.drain_events().iter().any(|event| matches!(
            event,
            RuntimeEvent::ConversationReadChanged { unread_count, .. }
                if *unread_count == Some(0)
        )));
    }

    #[test]
    fn receipt_can_race_forwarded_without_downgrading_delivery() {
        let mut runtime = runtime_with_sending_message();
        runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Delivered)
            .unwrap();
        let repeated_forwarded = runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::PeerPersisted)
            .unwrap();

        assert_eq!(repeated_forwarded.state, MessageState::Delivered);
    }

    #[test]
    fn offline_outcome_requeues_without_platform_selecting_state() {
        let mut runtime = runtime_with_sending_message();

        let message = runtime
            .apply_message_transport_outcome(
                Uuid::from_u128(1),
                MessageTransportOutcome::PeerUnavailable,
            )
            .unwrap();

        assert_eq!(message.state, MessageState::Queued);
    }

    #[test]
    fn live_relay_retry_advances_queued_message_after_recipient_returns() {
        let mut runtime = runtime_with_sending_message();
        runtime
            .apply_message_transport_outcome(
                Uuid::from_u128(1),
                MessageTransportOutcome::PeerUnavailable,
            )
            .unwrap();

        let effects = runtime.prepare_pending_message_sends().unwrap();
        assert_eq!(effects.len(), 1);
        assert_eq!(
            runtime.messages("peer-1").unwrap()[0].state,
            MessageState::Sending
        );

        let forwarded = runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::PeerPersisted)
            .unwrap();
        assert_eq!(forwarded.state, MessageState::Sent);
    }

    #[test]
    fn prepare_pending_message_sends_owns_retry_selection() {
        let mut runtime = runtime_with_queued_message();

        let effects = runtime.prepare_pending_message_sends().unwrap();

        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].message_id, Uuid::from_u128(1).to_string());
        assert_eq!(
            runtime.messages("peer-1").unwrap()[0].state,
            MessageState::Sending
        );
    }

    fn rebuild_with_existing_session(
        runtime: ClientRuntime<MemoryStorage, FakeTransport, FakeClock>,
    ) -> ClientRuntime<MemoryStorage, FakeTransport, FakeClock> {
        let (storage, transport, clock, session) = runtime.into_parts_with_session();
        ClientRuntime::with_session(storage, transport, clock, session)
    }

    #[test]
    fn open_conversation_survives_runtime_reconstruction() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();

        runtime.open_conversation("peer-1".to_owned()).unwrap();
        runtime.set_conversation_focus("peer-1", true).unwrap();
        runtime.drain_events();
        let mut runtime = rebuild_with_existing_session(runtime);

        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 0);
    }

    #[test]
    fn open_conversation_in_background_accumulates_unread() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 0,
            })
            .unwrap();
        runtime.open_conversation("peer-1".to_owned()).unwrap();
        runtime.set_conversation_focus("peer-1", true).unwrap();
        runtime.set_app_foreground(false);

        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 1);
    }

    #[test]
    fn close_conversation_clears_selection_across_runtime_reconstruction() {
        let mut runtime = runtime();
        runtime
            .storage
            .put_conversation(ConversationSummary {
                id: "peer-1".to_owned(),
                contact_installation_id: "peer-1".to_owned(),
                status: crate::ConversationState::Active,
                last_message_preview: "old".to_owned(),
                last_message_at: 10,
                unread_count: 4,
            })
            .unwrap();

        runtime.open_conversation("peer-1".to_owned()).unwrap();
        runtime.close_conversation();
        let mut runtime = rebuild_with_existing_session(runtime);

        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 5);
    }

    #[test]
    fn queued_events_survive_runtime_reconstruction_until_drained() {
        let mut runtime = runtime();
        runtime.emit_runtime_error("one");
        let mut runtime = rebuild_with_existing_session(runtime);
        runtime.emit_runtime_error("two");
        let messages = runtime
            .drain_events()
            .into_iter()
            .filter_map(|event| match event {
                RuntimeEvent::RuntimeError { message } => Some(message),
                _ => None,
            })
            .collect::<Vec<_>>();

        assert_eq!(messages, vec!["one".to_owned(), "two".to_owned()]);
    }
}
