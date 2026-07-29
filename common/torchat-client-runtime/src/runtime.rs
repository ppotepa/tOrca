use crate::pairing_rules::{PairingAction, merge_pairing_item, normalize_pairing_item};
use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteState, MessageSendEffect,
    MessageTransportOutcome, PairingItem, RuntimeClock, RuntimeCommand, RuntimeError, RuntimeEvent,
    RuntimeIdentity, RuntimeProfile, RuntimeResult, RuntimeSendEffect, RuntimeSession,
    RuntimeStorage, RuntimeTransport,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuntimeRequest {
    pub id: Option<String>,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuntimeResponse {
    pub id: Option<String>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl RuntimeResponse {
    pub fn ok<T: Serialize>(id: Option<String>, result: T) -> RuntimeResult<Self> {
        Ok(Self {
            id,
            ok: true,
            result: Some(serde_json::to_value(result)?),
            error: None,
        })
    }

    pub fn error(id: Option<String>, error: impl std::fmt::Display) -> Self {
        Self {
            id,
            ok: false,
            result: None,
            error: Some(error.to_string()),
        }
    }
}

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

    pub fn dispatch_request(&mut self, request: RuntimeRequest) -> RuntimeResponse {
        match self.dispatch_value(&request.method, request.params) {
            Ok(value) => RuntimeResponse {
                id: request.id,
                ok: true,
                result: Some(value),
                error: None,
            },
            Err(error) => RuntimeResponse::error(request.id, error),
        }
    }

    pub fn dispatch_value(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> RuntimeResult<serde_json::Value> {
        let command = parse_runtime_command(method, params)?;
        let value = match command {
            RuntimeCommand::BootstrapRuntime => serde_json::to_value(self.bootstrap_runtime()?)?,
            RuntimeCommand::ReportTorStatus { status } => {
                self.report_tor_status(status);
                serde_json::json!(true)
            }
            RuntimeCommand::ApplyRemoteProfile { profile } => {
                serde_json::to_value(self.apply_remote_profile(profile)?)?
            }
            RuntimeCommand::ReportRuntimeError { message } => {
                self.report_runtime_error(message);
                serde_json::json!(true)
            }
            RuntimeCommand::ReportRuntimeLog { message } => {
                self.report_runtime_log(message);
                serde_json::json!(true)
            }
            RuntimeCommand::Connect => serde_json::to_value(self.connect()?)?,
            RuntimeCommand::Identity => serde_json::to_value(self.identity()?)?,
            RuntimeCommand::Profile => serde_json::to_value(self.profile()?)?,
            RuntimeCommand::SetNickname { nickname } => {
                serde_json::to_value(self.set_nickname(nickname)?)?
            }
            RuntimeCommand::RefreshPairingCode => {
                serde_json::to_value(self.refresh_pairing_code()?)?
            }
            RuntimeCommand::PrepareSubmitPairingCode { code } => {
                serde_json::to_value(self.prepare_submit_pairing_code(code)?)?
            }
            RuntimeCommand::SubmitPairingCode { code } => {
                serde_json::to_value(self.submit_pairing_code(code)?)?
            }
            RuntimeCommand::PairingInbox => serde_json::to_value(self.pairing_inbox()?)?,
            RuntimeCommand::MergePairingInbox { items } => {
                serde_json::to_value(self.merge_pairing_inbox(items)?)?
            }
            RuntimeCommand::PairingOutbox => serde_json::to_value(self.pairing_outbox()?)?,
            RuntimeCommand::MergePairingOutbox { items } => {
                serde_json::to_value(self.merge_pairing_outbox(items)?)?
            }
            RuntimeCommand::Contacts => serde_json::to_value(self.contacts()?)?,
            RuntimeCommand::Conversations => serde_json::to_value(self.conversations()?)?,
            RuntimeCommand::Messages { id } => serde_json::to_value(self.messages(&id)?)?,
            RuntimeCommand::OpenConversation { id } => {
                self.open_conversation(id)?;
                serde_json::json!(true)
            }
            RuntimeCommand::CloseConversation => {
                self.close_conversation();
                serde_json::json!(true)
            }
            RuntimeCommand::VerifyContact { installation_id } => {
                self.verify_contact(&installation_id)?;
                serde_json::json!(true)
            }
            RuntimeCommand::PrepareAcceptPairing { pairing_id } => {
                serde_json::to_value(self.prepare_accept_pairing(&pairing_id)?)?
            }
            RuntimeCommand::CommitAcceptPairing {
                pairing_id,
                offer_invite_id,
                offer_payload,
            } => serde_json::to_value(self.commit_accept_pairing(
                &pairing_id,
                offer_invite_id,
                offer_payload,
            )?)?,
            RuntimeCommand::PrepareRejectPairing { pairing_id } => {
                serde_json::to_value(self.prepare_reject_pairing(&pairing_id)?)?
            }
            RuntimeCommand::CommitRejectPairing { pairing_id } => {
                serde_json::to_value(self.commit_reject_pairing(&pairing_id)?)?
            }
            RuntimeCommand::PrepareCancelPairing { pairing_id } => {
                serde_json::to_value(self.prepare_cancel_pairing(&pairing_id)?)?
            }
            RuntimeCommand::ConfirmPairingCancelled { pairing_id } => {
                self.confirm_pairing_cancelled(&pairing_id)?;
                serde_json::json!(true)
            }
            RuntimeCommand::PreparePendingSendEffects => {
                serde_json::to_value(self.prepare_pending_send_effects()?)?
            }
            RuntimeCommand::ApplyPairingPeerOutcome {
                pairing_id,
                outcome,
            } => serde_json::to_value(self.apply_pairing_peer_outcome(&pairing_id, outcome)?)?,
            RuntimeCommand::WelcomeAccepted {
                contact,
                open_conversation,
                invite_id,
            }
            | RuntimeCommand::BootstrapContact {
                contact,
                open_conversation,
                invite_id,
            } => serde_json::to_value(self.welcome_accepted(
                contact,
                open_conversation,
                invite_id,
            )?)?,
            RuntimeCommand::ArchivePairing { pairing_id } => {
                self.archive_pairing(&pairing_id)?;
                serde_json::json!(true)
            }
            RuntimeCommand::StartConversation { contact_id } => {
                serde_json::to_value(self.start_conversation(&contact_id)?)?
            }
            RuntimeCommand::SendMessage { id, text } => {
                serde_json::to_value(self.send_message(&id, text)?)?
            }
            RuntimeCommand::ReceiveMessage {
                id,
                text,
                message_id,
            } => {
                let message_id = message_id.as_deref().map(parse_uuid).transpose()?;
                serde_json::to_value(self.receive_message(&id, text, message_id)?)?
            }
            RuntimeCommand::ApplyMessageTransportOutcome {
                message_id,
                outcome,
            } => {
                let message_id = parse_uuid(&message_id)?;
                serde_json::to_value(self.apply_message_transport_outcome(message_id, outcome)?)?
            }
        };
        Ok(value)
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
        let code = self.transport.refresh_pairing_code()?;
        self.storage.put_pairing_code(code.clone())?;
        Ok(code)
    }

    pub fn prepare_submit_pairing_code(&self, code: String) -> RuntimeResult<String> {
        let normalized = code
            .chars()
            .filter(|value| value.is_ascii_digit())
            .collect::<String>();
        if normalized.len() != 8 {
            return Err(RuntimeError::InvalidParams(
                "pairing code must contain exactly eight digits".to_owned(),
            ));
        }
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
            let local_item = local
                .iter()
                .position(|item| item.pairing_id == remote_item.pairing_id)
                .map(|index| local.remove(index));
            let merge = merge_pairing_item(local_item, remote_item.clone());
            if merge.inserted {
                self.session.push_event(RuntimeEvent::InviteReceived {
                    pairing_id: Some(merge.item.pairing_id.clone()),
                    nickname: merge
                        .item
                        .sender
                        .as_ref()
                        .map(|sender| sender.nickname.clone()),
                });
                acknowledgements.push(crate::PairingAcknowledgeEffect {
                    pairing_id: merge.item.pairing_id.clone(),
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
                "pairing request cannot be prepared from its current state".to_owned(),
            ));
        }
        Ok(crate::PairingPreparation {
            pairing_id: item.pairing_id,
            recipient_installation_id: sender.installation_id,
            capability,
        })
    }

    pub fn commit_reject_pairing(&mut self, pairing_id: &str) -> RuntimeResult<RuntimeSendEffect> {
        let mut item = self
            .storage
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let recipient_installation_id = item
            .sender
            .as_ref()
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?
            .installation_id
            .clone();
        if item.state != InviteState::Rejected {
            if item.expires_at < self.clock.now_secs() {
                return Err(RuntimeError::Conflict(
                    "pairing request is expired".to_owned(),
                ));
            }
            item.state = transition_invite_state(&item.state, PairingAction::Reject)?;
            item = normalize_pairing_item(item);
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
        if !matches!(item.state, InviteState::Pending | InviteState::Accepted) {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be cancelled from its current state".to_owned(),
            ));
        }
        Ok(crate::PairingCancelEffect {
            pairing_id: pairing_id.to_owned(),
        })
    }

    pub fn confirm_pairing_cancelled(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        let mut item = self
            .storage
            .pairing_outbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id)
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        if item.state == InviteState::Cancelled {
            return Ok(());
        }
        if !matches!(item.state, InviteState::Pending | InviteState::Accepted) {
            return Err(RuntimeError::Conflict(
                "pairing request cannot be cancelled from its current state".to_owned(),
            ));
        }
        item.state = InviteState::Cancelled;
        item = normalize_pairing_item(item);
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
        let next_state = match outcome {
            crate::PairingPeerOutcome::OfferReceived => match item.state {
                InviteState::Pending | InviteState::Accepted => InviteState::Accepted,
                InviteState::Completed => InviteState::Completed,
                _ => {
                    return Err(RuntimeError::Conflict(
                        "pairing peer outcome is invalid for the current state".to_owned(),
                    ));
                }
            },
            crate::PairingPeerOutcome::RejectionReceived => match item.state {
                InviteState::Pending | InviteState::Accepted | InviteState::Rejected => {
                    InviteState::Rejected
                }
                _ => {
                    return Err(RuntimeError::Conflict(
                        "pairing peer outcome is invalid for the current state".to_owned(),
                    ));
                }
            },
            crate::PairingPeerOutcome::WelcomePrepared => match item.state {
                InviteState::Accepted | InviteState::Completed => InviteState::Completed,
                _ => {
                    return Err(RuntimeError::Conflict(
                        "pairing peer outcome is invalid for the current state".to_owned(),
                    ));
                }
            },
        };
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
        let mut items = self.storage.pairing_outbox()?;
        self.expire_pairing_items(&mut items, false)?;
        items.retain(|item| item.state != InviteState::Archived);
        items.sort_by(|a, b| {
            b.expires_at
                .cmp(&a.expires_at)
                .then(a.pairing_id.cmp(&b.pairing_id))
        });
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
        let conversation = self.promote_contact_with_status(
            contact.clone(),
            crate::ConversationState::Verifying,
            open_conversation,
        )?;
        let mut confirm_contact = None;

        if let Some(invite_id) = invite_id {
            let mut item = self
                .storage
                .pairing_inbox()?
                .into_iter()
                .find(|item| item.offer_invite_id.as_deref() == Some(invite_id.as_str()))
                .ok_or_else(|| {
                    RuntimeError::NotFound("pairing request does not exist".to_owned())
                })?;
            match item.state {
                InviteState::Accepted => {
                    item.state = InviteState::Completed;
                    item = normalize_pairing_item(item);
                    self.storage.put_pairing_inbox(item.clone())?;
                    self.session.push_event(RuntimeEvent::InviteStateChanged {
                        pairing_id: Some(item.pairing_id.clone()),
                        state: Some(InviteState::Completed),
                    });
                }
                InviteState::Completed => {}
                _ => {
                    return Err(RuntimeError::Conflict(
                        "welcome cannot complete pairing from its current state".to_owned(),
                    ));
                }
            }
            confirm_contact = Some(crate::PairingConfirmContactEffect {
                pairing_id: item.pairing_id,
                capability: item.capability.unwrap_or_default(),
                peer_installation_id: contact.installation_id,
            });
        }

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
        for remote_item in remote {
            let local_item = local
                .iter()
                .position(|item| item.pairing_id == remote_item.pairing_id)
                .map(|index| local.remove(index));
            let merge = merge_pairing_item(local_item, remote_item.clone());
            if merge.changed || merge.inserted {
                let state = merge.item.state;
                self.storage.put_pairing_outbox(merge.item.clone())?;
                self.session.push_event(RuntimeEvent::InviteStateChanged {
                    pairing_id: Some(merge.item.pairing_id.clone()),
                    state: Some(state),
                });
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
            acknowledgements: Vec::new(),
        })
    }

    pub fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        self.storage.contacts()
    }

    pub fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        self.storage.conversations()
    }

    pub fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        self.storage.messages(conversation_id)
    }

    pub fn open_conversation(&mut self, conversation_id: String) -> RuntimeResult<()> {
        self.session.select_conversation(conversation_id.clone());
        self.storage.mark_conversation_read(&conversation_id)?;
        self.session
            .push_event(RuntimeEvent::ConversationReadChanged {
                conversation_id: Some(conversation_id),
                unread_count: Some(0),
            });
        Ok(())
    }

    pub fn close_conversation(&mut self) {
        self.session.clear_selected_conversation();
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
        for mut conversation in self.storage.conversations()? {
            if conversation.contact_installation_id == installation_id
                || conversation.id == installation_id
            {
                conversation.status = crate::ConversationState::Active;
                self.storage.put_conversation(conversation)?;
            }
        }
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
        self.promote_contact_with_status(
            contact,
            crate::ConversationState::Active,
            open_conversation,
        )
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
            contact.nickname = contact.installation_id.clone();
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
            self.storage.mark_conversation_read(&conversation.id)?;
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
        let message = self.queue_outgoing_message(conversation_id, text)?;
        self.prepare_message_send(&message.id)
    }

    fn queue_outgoing_message(
        &mut self,
        conversation_id: &str,
        text: String,
    ) -> RuntimeResult<ChatMessage> {
        let text = text.trim();
        if text.is_empty() {
            return Err(RuntimeError::InvalidParams(
                "message text must not be empty".to_owned(),
            ));
        }
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
        let message_id = Uuid::new_v4();
        let created_at = self.clock.now_ms();
        let message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: true,
            body: text.to_owned(),
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

        let next_state = crate::message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;

        if next_state != message.state {
            message.state = next_state.clone();
            self.storage.put_message(message.clone())?;
            self.session.push_event(RuntimeEvent::MessageStateChanged {
                message_id: Some(parse_uuid(&message.id)?),
                state: Some(next_state),
            });
        }

        Ok(MessageSendEffect {
            message_id: message.id,
            conversation_id: message.conversation_id,
            recipient_installation_id: contact.installation_id,
            body: message.body,
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
        for item in self.storage.pairing_inbox()? {
            let Some(sender) = item.sender.as_ref() else {
                if matches!(item.state, InviteState::Accepted | InviteState::Rejected) {
                    return Err(RuntimeError::Conflict(
                        "pairing sender does not exist".to_owned(),
                    ));
                }
                continue;
            };
            let recipient_installation_id = sender.installation_id.clone();
            match item.state {
                InviteState::Accepted => {
                    if item.expires_at < self.clock.now_secs() {
                        continue;
                    }
                    if item.offer_payload.is_none() {
                        return Err(RuntimeError::Conflict(
                            "accepted pairing offer payload does not exist".to_owned(),
                        ));
                    }
                    effects.push(
                        pairing_send_effect(
                            item.pairing_id,
                            recipient_installation_id,
                            crate::PairingSendKind::Offer,
                            item.offer_payload,
                        )
                        .into(),
                    );
                }
                InviteState::Rejected => {
                    effects.push(
                        pairing_send_effect(
                            item.pairing_id,
                            recipient_installation_id,
                            crate::PairingSendKind::Rejection,
                            None,
                        )
                        .into(),
                    );
                }
                _ => {}
            }
        }
        effects.sort_by_key(|effect| effect.recipient_installation_id().to_owned());
        Ok(effects)
    }

    pub fn receive_message(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<Uuid>,
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
        let selected = self.session.selected_conversation_id() == Some(conversation_id);
        let current_unread_count = existing
            .as_ref()
            .map(|conversation| conversation.unread_count);
        let created_at = self.clock.now_ms();
        let message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: false,
            body: body.to_owned(),
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
            text: Some(body.to_owned()),
        });
        self.session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
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
                let state = transition_invite_state(&item.state, action)?;
                item.state = state;
                item = normalize_pairing_item(item);
                self.storage.put_pairing_inbox(item)?;
                next_state = Some(state);
                changed = true;
            }
        }
        for mut item in self.storage.pairing_outbox()? {
            if item.pairing_id == pairing_id {
                let state = transition_invite_state(&item.state, action)?;
                item.state = state;
                item = normalize_pairing_item(item);
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
        let mut changed = Vec::new();
        for item in items.iter_mut() {
            if item.state != InviteState::Pending || item.expires_at >= self.clock.now_secs() {
                continue;
            }
            item.state = InviteState::Expired;
            *item = normalize_pairing_item(item.clone());
            changed.push(item.clone());
        }
        for item in changed {
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

fn transition_invite_state(
    state: &InviteState,
    action: PairingAction,
) -> RuntimeResult<InviteState> {
    use InviteState::*;
    match (state, action) {
        (Pending, PairingAction::Accept) => Ok(Accepted),
        (Pending, PairingAction::Reject) => Ok(Rejected),
        (Pending, PairingAction::Expire) => Ok(Expired),
        (Pending, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted, PairingAction::Complete) => Ok(Completed),
        (Accepted, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted | Rejected | Completed | Expired | Cancelled, PairingAction::Archive) => {
            Ok(Archived)
        }
        _ => Err(RuntimeError::Conflict(
            "pairing request cannot be transitioned from its current state".to_owned(),
        )),
    }
}

fn parse_runtime_command(method: &str, params: serde_json::Value) -> RuntimeResult<RuntimeCommand> {
    let string = |key: &str| -> RuntimeResult<String> {
        params
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| RuntimeError::InvalidParams(format!("missing string param '{key}'")))
    };
    Ok(match method {
        "bootstrapRuntime" => RuntimeCommand::BootstrapRuntime,
        "reportTorStatus" => {
            RuntimeCommand::ReportTorStatus {
                status: serde_json::from_value(params.get("status").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'status'".into()),
                )?)?,
            }
        }
        "applyRemoteProfile" => {
            RuntimeCommand::ApplyRemoteProfile {
                profile: serde_json::from_value(params.get("profile").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'profile'".into()),
                )?)?,
            }
        }
        "reportRuntimeError" => RuntimeCommand::ReportRuntimeError {
            message: string("message")?,
        },
        "reportRuntimeLog" => RuntimeCommand::ReportRuntimeLog {
            message: string("message")?,
        },
        "connect" => RuntimeCommand::Connect,
        "identity" => RuntimeCommand::Identity,
        "profile" => RuntimeCommand::Profile,
        "setNickname" => RuntimeCommand::SetNickname {
            nickname: string("nickname")?,
        },
        "refreshPairingCode" => RuntimeCommand::RefreshPairingCode,
        "prepareSubmitPairingCode" => RuntimeCommand::PrepareSubmitPairingCode {
            code: string("code")?,
        },
        "submitPairingCode" => RuntimeCommand::SubmitPairingCode {
            code: string("code")?,
        },
        "pairingInbox" => RuntimeCommand::PairingInbox,
        "mergePairingInbox" => RuntimeCommand::MergePairingInbox {
            items: serde_json::from_value(
                params
                    .get("items")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!([])),
            )?,
        },
        "pairingOutbox" => RuntimeCommand::PairingOutbox,
        "mergePairingOutbox" => RuntimeCommand::MergePairingOutbox {
            items: serde_json::from_value(
                params
                    .get("items")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!([])),
            )?,
        },
        "prepareAcceptPairing" => RuntimeCommand::PrepareAcceptPairing {
            pairing_id: string("pairingId")?,
        },
        "commitAcceptPairing" => RuntimeCommand::CommitAcceptPairing {
            pairing_id: string("pairingId")?,
            offer_invite_id: string("offerInviteId")?,
            offer_payload: string("offerPayload")?,
        },
        "welcomeAccepted" => {
            RuntimeCommand::WelcomeAccepted {
                contact: serde_json::from_value(params.get("contact").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'contact'".into()),
                )?)?,
                open_conversation: params
                    .get("openConversation")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                invite_id: params
                    .get("inviteId")
                    .and_then(serde_json::Value::as_str)
                    .map(|value| value.to_owned()),
            }
        }
        "bootstrapContact" => {
            RuntimeCommand::BootstrapContact {
                contact: serde_json::from_value(params.get("contact").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'contact'".into()),
                )?)?,
                open_conversation: params
                    .get("openConversation")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                invite_id: params
                    .get("inviteId")
                    .and_then(serde_json::Value::as_str)
                    .map(|value| value.to_owned()),
            }
        }
        "prepareRejectPairing" => RuntimeCommand::PrepareRejectPairing {
            pairing_id: string("pairingId")?,
        },
        "commitRejectPairing" => RuntimeCommand::CommitRejectPairing {
            pairing_id: string("pairingId")?,
        },
        "archivePairing" => RuntimeCommand::ArchivePairing {
            pairing_id: string("pairingId")?,
        },
        "prepareCancelPairing" => RuntimeCommand::PrepareCancelPairing {
            pairing_id: string("pairingId")?,
        },
        "confirmPairingCancelled" => RuntimeCommand::ConfirmPairingCancelled {
            pairing_id: string("pairingId")?,
        },
        "preparePendingSendEffects" => RuntimeCommand::PreparePendingSendEffects,
        "applyPairingPeerOutcome" => {
            RuntimeCommand::ApplyPairingPeerOutcome {
                pairing_id: string("pairingId")?,
                outcome: serde_json::from_value(params.get("outcome").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'outcome'".into()),
                )?)?,
            }
        }
        "verifyContact" => RuntimeCommand::VerifyContact {
            installation_id: string("installationId")?,
        },
        "contacts" => RuntimeCommand::Contacts,
        "conversations" => RuntimeCommand::Conversations,
        "messages" => RuntimeCommand::Messages { id: string("id")? },
        "openConversation" => RuntimeCommand::OpenConversation { id: string("id")? },
        "closeConversation" => RuntimeCommand::CloseConversation,
        "startConversation" => RuntimeCommand::StartConversation {
            contact_id: string("contactId")?,
        },
        "sendMessage" => RuntimeCommand::SendMessage {
            id: string("id")?,
            text: string("text")?,
        },
        "receiveMessage" => RuntimeCommand::ReceiveMessage {
            id: string("id")?,
            text: string("text")?,
            message_id: params
                .get("messageId")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        },
        "applyMessageTransportOutcome" => {
            RuntimeCommand::ApplyMessageTransportOutcome {
                message_id: string("messageId")?,
                outcome: serde_json::from_value(params.get("outcome").cloned().ok_or_else(
                    || RuntimeError::InvalidParams("missing param 'outcome'".into()),
                )?)?,
            }
        }
        other => {
            return Err(RuntimeError::InvalidCommand(format!(
                "unknown runtime method '{other}'"
            )));
        }
    })
}

fn parse_uuid(value: &str) -> RuntimeResult<Uuid> {
    Uuid::parse_str(value).map_err(|_| RuntimeError::InvalidParams("invalid messageId".to_owned()))
}

fn pairing_send_effect(
    pairing_id: String,
    recipient_installation_id: String,
    kind: crate::PairingSendKind,
    payload: Option<String>,
) -> RuntimeSendEffect {
    RuntimeSendEffect {
        message: None,
        pairing: Some(crate::PairingSendEffect {
            pairing_id,
            recipient_installation_id,
            kind,
            payload,
        }),
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
        fn update_profile(&mut self, _nickname: &str) -> RuntimeResult<()> {
            Ok(())
        }
        fn refresh_pairing_code(&mut self) -> RuntimeResult<crate::InviteCode> {
            Ok(crate::InviteCode {
                code: "12345678".to_owned(),
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
            verification: VerificationState::Verified,
            dev: None,
        }
    }

    #[test]
    fn dispatcher_rejects_unknown_methods() {
        let mut runtime = runtime();
        let response = runtime.dispatch_request(RuntimeRequest {
            id: Some("1".to_owned()),
            method: "missing".to_owned(),
            params: serde_json::json!({}),
        });

        assert!(!response.ok);
        assert_eq!(response.id.as_deref(), Some("1"));
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
        let item = runtime.submit_pairing_code("1234 5678".to_owned()).unwrap();
        assert_eq!(item.pairing_id, "outbox-1");

        let error = runtime
            .submit_pairing_code("12345678".to_owned())
            .unwrap_err();
        assert!(matches!(error, RuntimeError::Conflict(_)));
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
    fn open_conversation_marks_unread_as_read() {
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
        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 0);
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
    fn forwarded_outcome_moves_sending_to_sent() {
        let mut runtime = runtime_with_sending_message();

        let message = runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Forwarded)
            .unwrap();

        assert_eq!(message.state, MessageState::Sent);
    }

    #[test]
    fn retryable_failure_can_requeue_sent_message() {
        let mut runtime = runtime_with_sending_message();
        runtime
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Forwarded)
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
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Forwarded)
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
        assert_eq!(event_count > 0, true);
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
            .apply_message_transport_outcome(Uuid::from_u128(1), MessageTransportOutcome::Forwarded)
            .unwrap();

        assert_eq!(repeated_forwarded.state, MessageState::Delivered);
    }

    #[test]
    fn offline_outcome_requeues_without_platform_selecting_state() {
        let mut runtime = runtime_with_sending_message();

        let message = runtime
            .apply_message_transport_outcome(
                Uuid::from_u128(1),
                MessageTransportOutcome::RecipientOffline,
            )
            .unwrap();

        assert_eq!(message.state, MessageState::Queued);
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
        runtime.drain_events();
        let mut runtime = rebuild_with_existing_session(runtime);

        runtime
            .receive_message("peer-1", "hello".to_owned(), None)
            .unwrap();

        assert_eq!(runtime.conversations().unwrap()[0].unread_count, 0);
    }

    #[test]
    fn close_conversation_survives_runtime_reconstruction() {
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
