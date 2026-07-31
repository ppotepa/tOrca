use crate::pairing_rules::{PairingAction, merge_pairing_item, normalize_pairing_item};
use crate::{
    ApplicationSnapshot, ChatMessage, ContactRecord, ConversationSummary, InviteState,
    MessageSendEffect, MessageTransportOutcome, PairingItem, PairingSummary, RuntimeClock,
    RuntimeError, RuntimeEvent, RuntimeIdentity, RuntimeProfile, RuntimeResult,
    RuntimeSendEffect, RuntimeSession, RuntimeStorage, RuntimeTransport, UiCheckpoint,
    APPLICATION_SNAPSHOT_SCHEMA_VERSION, logic::fallback_contact_nickname,
};
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

    pub fn bootstrap_runtime(&mut self) -> RuntimeResult<bool> {
        if !self.session.mark_bootstrap_emitted() {
            return Ok(false);
        }
        self.session.push_event(RuntimeEvent::RuntimeReady {
            protocol: torchat_core::PROTOCOL_VERSION,
        });
        if let Some(profile) = self.storage.profile()? {
            self.session
                .push_event(RuntimeEvent::ProfileReady { profile });
        }
        Ok(true)
    }

    pub fn report_tor_status(&mut self, status: crate::RuntimeTorStatus) {
        self.session.publish_tor_status(status);
    }

    pub fn apply_remote_profile(
        &mut self,
        profile: RuntimeProfile,
    ) -> RuntimeResult<RuntimeProfile> {
        self.storage.put_profile(profile.clone())?;
        self.session.push_event(RuntimeEvent::ProfileReady {
            profile: profile.clone(),
        });
        Ok(profile)
    }

    pub fn report_runtime_error(&mut self, message: String) {
        self.session.publish_runtime_error(message);
    }

    pub fn report_runtime_log(&mut self, message: String) {
        self.session.publish_runtime_log(message);
    }

    pub fn connect(&mut self) -> RuntimeResult<bool> {
        let status = self.transport.connect()?;
        self.emit_tor_status(status);
        Ok(true)
    }

    pub fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        self.storage.identity()
    }

    pub fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        self.storage.profile()
    }

    pub fn application_snapshot(
        &self,
        generation: u64,
        created_at_ms: i64,
        peer_endpoint_available: bool,
    ) -> RuntimeResult<ApplicationSnapshot> {
        let identity = self
            .storage
            .identity()?
            .ok_or_else(|| RuntimeError::Unavailable("runtime identity is not ready".to_owned()))?;
        let profile = self.storage.profile()?;
        let contacts = self.storage.contacts()?;
        let conversations = self.storage.conversations()?;
        let pending_inbox = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .filter(|item| item.state.is_pending())
            .count() as u32;
        let pending_outbox = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .filter(|item| item.state.is_outstanding())
            .count() as u32;

        Ok(ApplicationSnapshot {
            schema_version: APPLICATION_SNAPSHOT_SCHEMA_VERSION,
            generation,
            created_at_ms,
            identity,
            profile,
            contacts,
            conversations,
            pairing_summary: PairingSummary {
                pending_inbox,
                pending_outbox,
            },
            peer_endpoint_available,
            ui_checkpoint: UiCheckpoint::default(),
        }
        .normalize())
    }

    pub fn set_nickname(&mut self, nickname: String) -> RuntimeResult<RuntimeProfile> {
        let nickname = nickname.trim();
        if nickname.len() < 2 || nickname.chars().count() > 32 {
            return Err(RuntimeError::InvalidParams(
                "nickname must contain 2-32 characters".to_owned(),
            ));
        }
        let identity = self
            .storage
            .identity()?
            .ok_or_else(|| RuntimeError::Unavailable("runtime identity is not ready".to_owned()))?;
        self.transport.update_profile(nickname)?;
        let profile = RuntimeProfile::from_identity(&identity, nickname.to_owned());
        self.storage.put_profile(profile.clone())?;
        self.session.push_event(RuntimeEvent::ProfileReady {
            profile: profile.clone(),
        });
        Ok(profile)
    }

    pub fn refresh_pairing_code(&mut self) -> RuntimeResult<crate::InviteCode> {
        self.require_pairing_profile_ready()?;
        let code = self.transport.refresh_pairing_code()?;
        self.storage.put_pairing_code(code.clone())?;
        Ok(code)
    }

    pub fn prepare_submit_pairing_code(&mut self, code: String) -> RuntimeResult<String> {
        let normalized = code
            .chars()
            .filter(|value| value.is_ascii_digit())
            .collect::<String>();
        if normalized.len() != 8 {
            return Err(RuntimeError::InvalidParams(
                "pairing code must contain exactly eight digits".to_owned(),
            ));
        }
        let mut outbox = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut outbox, false)?;
        self.complete_outbox_pairings_for_existing_contacts()?;
        if self
            .storage
            .pairing_outbox()?
            .iter()
            .any(|item| item.state.is_outstanding())
        {
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
        for mut item in self.storage.pairing_outbox()? {
            let target_is_contact = item
                .sender
                .as_ref()
                .is_some_and(|target| contact_ids.contains(&target.installation_id));
            if !item.state.is_outstanding() || !target_is_contact {
                continue;
            }
            item.state = crate::InviteState::Completed;
            item = normalize_pairing_item(item);
            self.storage.put_pairing_outbox(item.clone())?;
            self.session.push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(item.pairing_id),
                state: Some(crate::InviteState::Completed),
            });
        }
        Ok(())
    }

    pub fn reconcile_outbox_pairing_contact(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<()> {
        let contact = self
            .storage
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        let outstanding = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .filter(|item| item.state.is_outstanding())
            .collect::<Vec<_>>();
        if outstanding.is_empty() {
            return Ok(());
        }
        let explicit_matches = outstanding
            .iter()
            .filter(|item| {
                item.sender
                    .as_ref()
                    .is_some_and(|sender| sender.installation_id == installation_id)
            })
            .count();
        let allow_single_unbound_repair = explicit_matches == 0 && outstanding.len() == 1;
        for mut item in outstanding {
            let matches_contact = item
                .sender
                .as_ref()
                .is_some_and(|sender| sender.installation_id == installation_id);
            if !matches_contact && !allow_single_unbound_repair {
                continue;
            }
            item.sender = Some(contact.clone());
            item.state = InviteState::Completed;
            item = normalize_pairing_item(item);
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
        let item = normalize_pairing_item(self.transport.submit_pairing_code(&normalized)?);
        self.storage.put_pairing_outbox(item.clone())?;
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(item.pairing_id.clone()),
            state: Some(item.state),
        });
        Ok(item)
    }

    fn require_pairing_profile_ready(&self) -> RuntimeResult<()> {
        let profile = self
            .storage
            .profile()?
            .ok_or_else(|| RuntimeError::Unavailable("runtime profile is not ready".to_owned()))?;
        if profile.nickname.trim().chars().count() < 2 {
            return Err(RuntimeError::Conflict(
                "set nickname before generating a pairing code".to_owned(),
            ));
        }
        Ok(())
    }

    pub fn pairing_inbox(&mut self) -> RuntimeResult<crate::PairingSyncResult> {
        let remote = self.transport.pairing_inbox()?;
        self.merge_pairing_inbox(remote)
    }

    pub fn merge_pairing_inbox(
        &mut self,
        remote: Vec<PairingItem>,
    ) -> RuntimeResult<crate::PairingSyncResult> {
        let mut local = self.storage.pairing_inbox()?;
        self.expire_pairing_items(&mut local, true)?;
        let mut acknowledgements = Vec::new();
        for remote_item in remote {
            let pairing_id = remote_item.pairing_id.clone();
            let local_item = local
                .iter()
                .position(|item| item.pairing_id == remote_item.pairing_id)
                .map(|index| local.remove(index));
            let merge = merge_pairing_item(local_item, remote_item.clone());
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
                local.push(item);
                continue;
            }
            if merge.changed || merge.inserted {
                self.storage.put_pairing_inbox(merge.item.clone())?;
            }
            local.push(merge.item);
        }
        local.retain(|item| item.state != InviteState::Archived);
        local.sort_by(|a, b| {
            b.expires_at
                .cmp(&a.expires_at)
                .then(a.pairing_id.cmp(&b.pairing_id))
        });
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
        let sender = item
            .sender
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
        let capability = item.capability.ok_or_else(|| {
            RuntimeError::Conflict("pairing capability does not exist".to_owned())
        })?;
        if item.expires_at < self.clock.now_secs() {
            return Err(RuntimeError::Conflict(
                "pairing request is expired".to_owned(),
            ));
        }
        if !item.state.is_pending() {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be prepared from its current state".to_owned(),
            ));
        }
        Ok(crate::PairingPreparation {
            pairing_id: item.pairing_id,
            recipient_installation_id: sender.installation_id,
            capability,
        })
    }

    pub fn commit_accept_pairing(
        &mut self,
        pairing_id: &str,
        offer_invite_id: String,
        offer_payload: String,
    ) -> RuntimeResult<RuntimeSendEffect> {
        if offer_invite_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "offerInviteId must not be empty".to_owned(),
            ));
        }
        if offer_payload.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "offerPayload must not be empty".to_owned(),
            ));
        }
        let mut item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let sender = item
            .sender
            .as_ref()
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
        if item.state == InviteState::Accepted {
            if item.offer_invite_id.as_deref() == Some(offer_invite_id.as_str())
                && item.offer_payload.as_deref() == Some(offer_payload.as_str())
            {
                return Ok(pairing_send_effect(
                    item.pairing_id,
                    sender.installation_id.clone(),
                    crate::PairingSendKind::Offer,
                    item.offer_payload,
                ));
            }
            return Err(RuntimeError::Conflict(
                "accepted pairing has different offer artifacts".to_owned(),
            ));
        }
        if item.expires_at < self.clock.now_secs() {
            return Err(RuntimeError::Conflict(
                "pairing request is expired".to_owned(),
            ));
        }
        let state = transition_invite_state(&item.state, PairingAction::Accept)?;
        let recipient_installation_id = sender.installation_id.clone();
        item.state = state;
        item.offer_invite_id = Some(offer_invite_id);
        item.offer_payload = Some(offer_payload);
        item = normalize_pairing_item(item);
        self.storage.put_pairing_inbox(item.clone())?;
        self.session.push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(pairing_id.to_owned()),
            state: Some(state),
        });
        Ok(pairing_send_effect(
            item.pairing_id,
            recipient_installation_id,
            crate::PairingSendKind::Offer,
            item.offer_payload,
        ))
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
        let sender = item
            .sender
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
        let capability = item.capability.ok_or_else(|| {
            RuntimeError::Conflict("pairing capability does not exist".to_owned())
        })?;
        if item.expires_at < self.clock.now_secs() {
            return Err(RuntimeError::Conflict(
                "pairing request is expired".to_owned(),
            ));
        }
        if !item.state.is_pending() {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be prepared from its current state".to_owned()))?;
        }
        Ok(crate::PairingPreparation {
            pairing_id: item.pairing_id,
            recipient_installation_id: sender.installation_id,
            capability,
        })
    }

    pub fn commit_reject_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<RuntimeSendEffect> {
        let item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let sender = item
            .sender
            .as_ref()
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
        let capability = item.capability.clone().ok_or_else(|| {
            RuntimeError::Conflict("pairing capability does not exist".to_owned())
        })?;
        let recipient_installation_id = sender.installation_id.clone();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            runtime.reject_pairing(pairing_id)?;
            Ok(())
        })?;
        self.session.extend_events(runtime_events);
        Ok(RuntimeSendEffect::Pairing(PairingSendEffect {
            pairing_id: pairing_id.to_owned(),
            recipient_installation_id,
            kind: crate::PairingSendKind::Rejection,
            payload: capability,
        }))
    }

    // Remaining runtime implementation unchanged.
    include!("runtime_tail.inc");
}
