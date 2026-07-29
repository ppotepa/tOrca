use anyhow::{Context, Result};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::Path,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use torchat_client_runtime::InviteState;
use torchat_client_runtime::contact_card_from_invite;
use torchat_core::{
    ContactInvite,
    application::ApplicationPayloadV1,
    mls::MlsMember,
    relay::{RelayEnvelope, RelayPayloadV1},
};

use crate::{
    DesktopState,
    model::{PairingCodeResponse, PairingRequestResponse},
    store::{DeliveryReceiptRecord, LocalStore, ReceivedEnvelope, StoredMessage},
    transport::RelayCommand,
};

impl torchat_client_runtime::RuntimePairingStateLike for crate::model::PairingInboxItem {
    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }
}

impl torchat_client_runtime::RuntimePairingStateLike for &crate::model::PairingInboxItem {
    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }
}

impl torchat_client_runtime::RuntimePairingIdLike for crate::model::PairingInboxItem {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }
}

impl torchat_client_runtime::RuntimePairingIdLike for &crate::model::PairingInboxItem {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }
}

impl torchat_client_runtime::RuntimePairingIdLike for PairingRequestResponse {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }
}

impl torchat_client_runtime::RuntimePairingIdLike for &PairingRequestResponse {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }
}

impl torchat_client_runtime::RuntimePairingUuidLike for crate::model::PairingInboxItem {
    fn runtime_pairing_uuid(&self) -> uuid::Uuid {
        self.pairing_id
    }
}

impl torchat_client_runtime::RuntimePairingUuidLike for &crate::model::PairingInboxItem {
    fn runtime_pairing_uuid(&self) -> uuid::Uuid {
        self.pairing_id
    }
}

impl torchat_client_runtime::RuntimePairingUuidLike for PairingRequestResponse {
    fn runtime_pairing_uuid(&self) -> uuid::Uuid {
        self.pairing_id
    }
}

impl torchat_client_runtime::RuntimePairingUuidLike for &PairingRequestResponse {
    fn runtime_pairing_uuid(&self) -> uuid::Uuid {
        self.pairing_id
    }
}

impl torchat_client_runtime::RuntimePairingStateLike for PairingRequestResponse {
    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }
}

impl torchat_client_runtime::RuntimePairingStateLike for &PairingRequestResponse {
    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }
}

impl torchat_client_runtime::RuntimePairingExpiryLike for PairingRequestResponse {
    fn runtime_pairing_expires_at(&self) -> i64 {
        self.expires_at
    }

    fn runtime_set_pairing_state(&mut self, state: InviteState) {
        self.state = state;
    }
}

impl torchat_client_runtime::RuntimePairingTransitionLike for PairingRequestResponse {
    fn runtime_pairing_transition_id(&self) -> uuid::Uuid {
        self.pairing_id
    }

    fn runtime_pairing_transition_state(&self) -> InviteState {
        self.state
    }

    fn runtime_set_pairing_transition_state(&mut self, state: InviteState) {
        self.state = state;
    }
}

impl torchat_client_runtime::RuntimePairingExpiryLike for crate::model::PairingInboxItem {
    fn runtime_pairing_expires_at(&self) -> i64 {
        self.expires_at
    }

    fn runtime_set_pairing_state(&mut self, state: InviteState) {
        self.state = state;
    }
}

impl torchat_client_runtime::RuntimePairingTransitionLike for crate::model::PairingInboxItem {
    fn runtime_pairing_transition_id(&self) -> uuid::Uuid {
        self.pairing_id
    }

    fn runtime_pairing_transition_state(&self) -> InviteState {
        self.state
    }

    fn runtime_set_pairing_transition_state(&mut self, state: InviteState) {
        self.state = state;
    }
}

pub fn load_dev_snapshot(path: &Path, field: &str) -> Result<Vec<u8>> {
    let value: serde_json::Value = serde_json::from_str(&fs::read_to_string(path)?)?;
    let encoded = value
        .get(field)
        .and_then(serde_json::Value::as_str)
        .with_context(|| format!("fixture has no {field}"))?;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(anyhow::Error::from)
}

pub fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default()
}

pub fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or_default()
}

pub fn load_json_secret<T: DeserializeOwned>(store: &LocalStore, key: &str) -> Result<Option<T>> {
    if let Some(value) = store.secret(key)? {
        Ok(Some(serde_json::from_slice(&value)?))
    } else {
        Ok(None)
    }
}

pub fn persist_json_secret<T: Serialize>(store: &LocalStore, key: &str, value: &T) -> Result<()> {
    store.put_secret(key, &serde_json::to_vec(value)?)
}

pub fn wait_for_relay(state: &mut DesktopState, timeout: std::time::Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    while !state.connected && Instant::now() < deadline {
        state.tick();
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    if state.connected {
        Ok(())
    } else {
        anyhow::bail!(
            "Relay nie jest jeszcze gotowy po {} s; sprawdź status Tor",
            timeout.as_secs()
        )
    }
}

pub fn consume_invite(state: &DesktopState, invite_id: &str) -> Result<()> {
    anyhow::ensure!(
        state.store.consume_invite(invite_id)?,
        "zaproszenie zostało już użyte"
    );
    Ok(())
}

pub fn apply_peer_selection(state: &mut DesktopState, peer: &str) -> Result<()> {
    crate::runtime_adapter::open_conversation_with_runtime(state, peer)?;
    state.open_selected_peer_view(peer)?;
    Ok(())
}

pub fn finalize_welcome_pairing(
    state: &mut DesktopState,
    invite_id: &str,
    _peer_installation_id: &str,
) -> Result<()> {
    state.pending_welcomes.remove(invite_id);
    state.persist_pending_welcomes()?;
    Ok(())
}

pub fn accept_invite(state: &mut DesktopState, value: &str) -> Result<()> {
    let invite = ContactInvite::parse(value.trim()).map_err(anyhow::Error::msg)?;
    anyhow::ensure!(
        invite.installation_id != state.identity.installation_id(),
        "nie można zaprosić samego siebie"
    );
    consume_invite(state, &invite.invite_id)?;
    let card = contact_card_from_invite(&invite);
    let member =
        MlsMember::create(state.identity.public_key().as_bytes()).map_err(anyhow::Error::msg)?;
    let mut direct = member.create_conversation().map_err(anyhow::Error::msg)?;
    let (welcome, tree) = direct
        .invite(
            &URL_SAFE_NO_PAD
                .decode(invite.key_package)
                .map_err(|_| anyhow::anyhow!("nieprawidłowy KeyPackage"))?,
        )
        .map_err(anyhow::Error::msg)?;
    promote_contact_with_conversation(state, card.clone(), direct, None)?;
    let ciphertext = RelayPayloadV1::welcome(
        state.identity.as_ref(),
        &state.nickname,
        card.installation_id.clone(),
        invite.invite_id.clone(),
        &welcome,
        &tree,
    )
    .encode()
    .map_err(anyhow::Error::msg)?;
    state.pending_welcomes.insert(
        invite.invite_id.clone(),
        (card.installation_id.clone(), ciphertext.clone()),
    );
    state.persist_pending_welcomes()?;
    state
        .relay_commands
        .try_send(crate::transport::RelayCommand::Send {
            message_id: uuid::Uuid::new_v4(),
            recipient: card.installation_id,
            ciphertext,
        })
        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
    Ok(())
}

pub fn accept_pairing(state: &mut DesktopState, pairing_id: uuid::Uuid) -> Result<()> {
    eprintln!("[TorChat-Pairing] acceptPairing start pairing_id={pairing_id}");
    let preparation: torchat_client_runtime::PairingPreparation =
        serde_json::from_value(crate::runtime_adapter::dispatch_local_runtime_command(
            state,
            "prepareAcceptPairing",
            serde_json::json!({"pairingId": pairing_id.to_string()}),
        )?)?;
    eprintln!(
        "[TorChat-Pairing] acceptPairing prepared pairing_id={} recipient={}",
        pairing_id, preparation.recipient_installation_id
    );
    let invite = state.build_invite(Some(preparation.recipient_installation_id.clone()))?;
    let invite_id = ContactInvite::parse(&invite)
        .map_err(anyhow::Error::msg)?
        .invite_id;
    let payload =
        RelayPayloadV1::pairing_offer(pairing_id.to_string(), preparation.capability, invite)
            .encode()
            .map_err(anyhow::Error::msg)?;
    let effect: torchat_client_runtime::RuntimeSendEffect =
        serde_json::from_value(crate::runtime_adapter::dispatch_local_runtime_command(
            state,
            "commitAcceptPairing",
            serde_json::json!({
                "pairingId": pairing_id.to_string(),
                "offerInviteId": invite_id,
                "offerPayload": payload,
            }),
        )?)?;
    eprintln!(
        "[TorChat-Pairing] acceptPairing committed pairing_id={} invite_id={}",
        pairing_id, invite_id
    );
    state.dispatch_runtime_send_effect(effect)?;
    eprintln!("[TorChat-Pairing] acceptPairing dispatched pairing_id={pairing_id}");
    Ok(())
}

pub fn reject_pairing(state: &mut DesktopState, pairing_id: uuid::Uuid) -> Result<()> {
    eprintln!("[TorChat-Pairing] rejectPairing start pairing_id={pairing_id}");
    let _: torchat_client_runtime::PairingPreparation =
        serde_json::from_value(crate::runtime_adapter::dispatch_local_runtime_command(
            state,
            "prepareRejectPairing",
            serde_json::json!({"pairingId": pairing_id.to_string()}),
        )?)?;
    let effect: torchat_client_runtime::RuntimeSendEffect =
        serde_json::from_value(crate::runtime_adapter::dispatch_local_runtime_command(
            state,
            "commitRejectPairing",
            serde_json::json!({"pairingId": pairing_id.to_string()}),
        )?)?;
    state.dispatch_runtime_send_effect(effect)?;
    eprintln!("[TorChat-Pairing] rejectPairing dispatched pairing_id={pairing_id}");
    Ok(())
}

pub fn handle_relay_envelope(state: &mut DesktopState, envelope: RelayEnvelope) -> Result<()> {
    let payload = RelayPayloadV1::decode(&envelope.ciphertext).map_err(anyhow::Error::msg)?;
    match &payload {
        RelayPayloadV1::PairingOffer {
            pairing_id, invite, ..
        } => {
            if let Err(error) = accept_invite(state, invite) {
                // Pairing offers can be retried over the live-only relay.
                // Once the invite was consumed, a duplicate is harmless.
                if !error.to_string().contains("już użyte") {
                    return Err(error);
                }
                if let Ok(parsed) = ContactInvite::parse(invite)
                    && let Some((recipient, ciphertext)) =
                        state.pending_welcomes.get(&parsed.invite_id)
                {
                    let _ = state
                        .relay_commands
                        .try_send(crate::transport::RelayCommand::Send {
                            message_id: uuid::Uuid::new_v4(),
                            recipient: recipient.clone(),
                            ciphertext: ciphertext.clone(),
                        });
                }
            }
            if let Ok(pairing_id) = uuid::Uuid::parse_str(pairing_id) {
                crate::runtime_adapter::dispatch_local_runtime_command(
                    state,
                    "applyPairingPeerOutcome",
                    serde_json::json!({
                        "pairingId": pairing_id.to_string(),
                        "outcome": torchat_client_runtime::PairingPeerOutcome::OfferReceived,
                    }),
                )?;
                crate::runtime_adapter::dispatch_local_runtime_command(
                    state,
                    "applyPairingPeerOutcome",
                    serde_json::json!({
                        "pairingId": pairing_id.to_string(),
                        "outcome": torchat_client_runtime::PairingPeerOutcome::WelcomePrepared,
                    }),
                )?;
            }
        }
        RelayPayloadV1::PairingRejected { pairing_id, .. } => {
            if let Ok(pairing_id) = uuid::Uuid::parse_str(pairing_id) {
                crate::runtime_adapter::dispatch_local_runtime_command(
                    state,
                    "applyPairingPeerOutcome",
                    serde_json::json!({
                        "pairingId": pairing_id.to_string(),
                        "outcome": torchat_client_runtime::PairingPeerOutcome::RejectionReceived,
                    }),
                )?;
            }
        }
        RelayPayloadV1::Welcome { sender, .. } => {
            payload
                .verify_welcome(&envelope.sender, &state.identity.installation_id())
                .map_err(anyhow::Error::msg)?;
            let (invite_id, welcome, tree) =
                payload.decode_welcome().map_err(anyhow::Error::msg)?;
            let member = state
                .pending_member
                .take()
                .context("no pending MLS invitation for Welcome")?;
            let snapshot = member.snapshot().map_err(anyhow::Error::msg)?;
            let conversation = match member.accept_conversation(&welcome, &tree) {
                Ok(value) => value,
                Err(error) => {
                    state.pending_member = Some(
                        MlsMember::restore(&snapshot, state.identity.public_key().as_bytes())
                            .map_err(anyhow::Error::msg)?,
                    );
                    return Err(anyhow::Error::msg(error));
                }
            };
            state.pending_member = Some(
                MlsMember::create(state.identity.public_key().as_bytes())
                    .map_err(anyhow::Error::msg)?,
            );
            promote_contact_with_conversation(
                state,
                sender.clone(),
                conversation,
                Some(&invite_id),
            )?;
            finalize_welcome_pairing(state, &invite_id, &envelope.sender)?;
        }
        RelayPayloadV1::Application { .. } => {
            let peer = envelope.sender.clone();
            let message_id = envelope.message_id;
            let ciphertext = payload.decode_application().map_err(anyhow::Error::msg)?;
            let ciphertext_hash = Sha256::digest(&ciphertext).to_vec();
            if let Some(existing) = state
                .store
                .received_envelope(&peer, &message_id.to_string())?
            {
                if existing.ciphertext_hash != ciphertext_hash {
                    return Err(anyhow::anyhow!(
                        "duplicate envelope has different ciphertext"
                    ));
                }
                return Ok(());
            }
            let (sent_at, body, snapshot) = {
                let conversation = state
                    .conversations
                    .get_mut(&envelope.sender)
                    .context("message received before MLS Welcome")?;
                let plaintext = conversation
                    .decrypt(&ciphertext)
                    .map_err(anyhow::Error::msg)?;
                let application =
                    ApplicationPayloadV1::decode(&plaintext).map_err(anyhow::Error::msg)?;
                let (sent_at, body) = match application {
                    ApplicationPayloadV1::Message {
                        message_id: payload_message_id,
                        sent_at,
                        body,
                        ..
                    } => {
                        if payload_message_id != message_id {
                            return Err(anyhow::anyhow!("application messageId mismatch"));
                        }
                        (sent_at, body)
                    }
                    ApplicationPayloadV1::DeliveryReceipt {
                        message_id: delivered_message_id,
                        ..
                    } => {
                        crate::runtime_adapter::dispatch_local_runtime_command(
                            state,
                            "applyMessageTransportOutcome",
                            serde_json::json!({
                                "messageId": delivered_message_id.to_string(),
                                "outcome": torchat_client_runtime::MessageTransportOutcome::Delivered,
                            }),
                        )?;
                        return Ok(());
                    }
                };
                let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
                (sent_at, body, snapshot)
            };
            crate::runtime_adapter::dispatch_local_runtime_command(
                state,
                "receiveMessage",
                serde_json::json!({
                    "id": peer,
                    "text": body,
                    "messageId": message_id.to_string(),
                }),
            )?;
            let conversation_summary = state
                .store
                .runtime_conversation(&peer)?
                .context("runtime conversation is missing from desktop store")?;
            let message = StoredMessage {
                id: message_id.to_string(),
                peer: peer.clone(),
                outgoing: false,
                body: body.clone(),
                state: torchat_client_runtime::MessageState::Delivered,
                created_at: sent_at,
                relay_payload: None,
                attempt_count: 0,
                last_attempt_at: None,
                next_attempt_at: 0,
                ack_deadline: None,
                last_transport_error: None,
            };
            let receipt = DeliveryReceiptRecord {
                message_id: message_id.to_string(),
                original_sender: envelope.sender.clone(),
                state: "PENDING".to_owned(),
                attempt_count: 0,
                next_attempt_at: 0,
                created_at: sent_at,
                last_error: None,
            };
            state.store.persist_inbound_application(
                &ReceivedEnvelope {
                    sender_installation_id: peer.clone(),
                    message_id: message_id.to_string(),
                    ciphertext_hash,
                    received_at: sent_at,
                    receipt_state: "PENDING".to_owned(),
                },
                &message,
                &conversation_summary,
                &snapshot,
                &receipt,
            )?;
            if state.selected_peer.as_deref() == Some(&peer) {
                state.messages = state.store.messages(&peer)?;
            }
        }
    }
    state.flush_pending_delivery_receipts()?;
    Ok(())
}

pub fn promote_contact_with_conversation(
    state: &mut DesktopState,
    card: torchat_core::relay::ContactCard,
    conversation: torchat_core::mls::DirectConversation,
    invite_id: Option<&str>,
) -> Result<()> {
    let result: torchat_client_runtime::WelcomeAcceptedResult =
        serde_json::from_value(crate::runtime_adapter::dispatch_local_runtime_command(
            state,
            "welcomeAccepted",
            serde_json::json!({
                "contact": torchat_client_runtime::contact_record_from_card(&card, false),
                "openConversation": true,
                "inviteId": invite_id,
            }),
        )?)?;
    if let Some(confirm) = result.confirm_contact {
        let _ = state
            .relay_commands
            .try_send(crate::transport::RelayCommand::ConfirmContact {
                capability: confirm.capability,
                peer: confirm.peer_installation_id,
            });
    }
    let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
    state
        .store
        .put_conversation_mls(&card.installation_id, &snapshot)?;
    state
        .conversations
        .insert(card.installation_id.clone(), conversation);
    state.open_selected_peer_view(&card.installation_id)?;
    Ok(())
}

pub fn wait_for_pairing_code(
    state: &mut DesktopState,
    timeout: std::time::Duration,
) -> Result<PairingCodeResponse> {
    if !state.connected {
        wait_for_relay(state, std::time::Duration::from_secs(90))?;
    }
    state.pairing_code = None;
    state.error.clear();
    state
        .relay_commands
        .try_send(RelayCommand::RefreshPairingCode)
        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
    let deadline = Instant::now() + timeout;
    while state.pairing_code.is_none() && Instant::now() < deadline {
        state.tick();
        bail_on_relay_command_error(state)?;
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    state
        .pairing_code
        .clone()
        .context("relay did not return a pairing code")
}

pub fn wait_for_pairing_request(
    state: &mut DesktopState,
    code: String,
    timeout: std::time::Duration,
) -> Result<PairingRequestResponse> {
    if !state.connected {
        wait_for_relay(state, std::time::Duration::from_secs(90))?;
    }
    let existing_ids = state
        .pairing_outbox
        .iter()
        .map(|item| item.pairing_id)
        .collect::<std::collections::HashSet<_>>();
    state.error.clear();
    state
        .relay_commands
        .try_send(RelayCommand::SubmitPairingCode(code))
        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
    let deadline = Instant::now() + timeout;
    while !state
        .pairing_outbox
        .iter()
        .any(|item| !existing_ids.contains(&item.pairing_id))
        && Instant::now() < deadline
    {
        state.tick();
        bail_on_relay_command_error(state)?;
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    state
        .pairing_outbox
        .last()
        .cloned()
        .filter(|item| !existing_ids.contains(&item.pairing_id))
        .context("pairing request was not created")
}

pub fn bail_on_relay_command_error(state: &DesktopState) -> Result<()> {
    if state.error.is_empty() {
        Ok(())
    } else {
        anyhow::bail!("{}", state.error)
    }
}

#[cfg(test)]
mod tests {
    use torchat_client_runtime::{InviteState, PairingAction};
    use torchat_core::relay::ContactCard;

    #[test]
    fn transition_pairing_record_updates_inbox_and_outbox_states() {
        let pairing_id =
            uuid::Uuid::parse_str("00000000-0000-4000-8000-000000000001").expect("valid uuid");
        let mut inbox = vec![crate::model::PairingInboxItem {
            pairing_id,
            sender: ContactCard {
                installation_id: "peer".into(),
                public_key: "pk".into(),
                fingerprint: "fp".into(),
                nickname: "Peer".into(),
            },
            capability: "cap".into(),
            expires_at: 1,
            state: InviteState::Pending,
            offer_invite_id: None,
            offer_payload: None,
        }];
        let mut outbox = vec![crate::model::PairingRequestResponse {
            pairing_id,
            expires_at: 1,
            state: InviteState::Pending,
        }];

        assert!(
            torchat_client_runtime::transition_pairing_record(
                &mut inbox,
                pairing_id,
                PairingAction::Accept,
            )
            .unwrap()
        );
        assert_eq!(inbox[0].state, InviteState::Accepted);

        assert!(
            torchat_client_runtime::transition_pairing_record(
                &mut outbox,
                pairing_id,
                PairingAction::Cancel,
            )
            .unwrap()
        );
        assert_eq!(outbox[0].state, InviteState::Cancelled);
    }
}
