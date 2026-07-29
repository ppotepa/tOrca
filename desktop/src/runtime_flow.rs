use anyhow::{Context, Result};
use torchat_client_runtime::{
    MessageSendEffect, MessageTransportOutcome, PairingSendEffect, PairingSendKind,
    RuntimeSendEffect, RuntimeTransportFact,
};
use torchat_core::application::ApplicationPayloadV1;
use torchat_core::relay::RelayPayloadV1;
use uuid::Uuid;

use crate::DesktopState;
use crate::runtime_support::{apply_peer_selection, handle_relay_envelope};

impl DesktopState {
    pub fn receive_envelope(&mut self, envelope: torchat_core::relay::RelayEnvelope) -> Result<()> {
        handle_relay_envelope(self, envelope)
    }

    pub fn select_peer(&mut self, peer: &str) -> Result<()> {
        apply_peer_selection(self, peer)
    }

    pub fn clear_selected_peer_view(&mut self) {
        self.selected_peer = None;
        self.messages.clear();
    }

    pub fn open_selected_peer_view(&mut self, peer: &str) -> Result<()> {
        self.selected_peer = Some(peer.to_owned());
        self.messages = self.store.messages(peer)?;
        Ok(())
    }

    pub fn send(&mut self, text: &str) -> Result<()> {
        let text = text.trim();
        if text.is_empty() {
            return Ok(());
        }
        let peer = self.selected_peer.clone().context("wybierz rozmowę")?;
        let value = crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "sendMessage",
            serde_json::json!({ "id": peer, "text": text }),
        )?;
        let effect: RuntimeSendEffect = serde_json::from_value(value)?;
        self.dispatch_runtime_send_effect(effect)
    }

    pub fn flush_pending_send_effects(&mut self) -> Result<()> {
        let value = crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "preparePendingSendEffects",
            serde_json::json!({}),
        )?;
        let effects: Vec<RuntimeSendEffect> = serde_json::from_value(value)?;
        self.dispatch_runtime_send_effects(effects)
    }

    pub fn dispatch_runtime_send_effects<I, E>(&mut self, effects: I) -> Result<()>
    where
        I: IntoIterator<Item = E>,
        E: Into<RuntimeSendEffect>,
    {
        for effect in effects {
            self.dispatch_runtime_send_effect(effect)?;
        }
        Ok(())
    }

    pub fn dispatch_runtime_send_effect<E>(&mut self, effect: E) -> Result<()>
    where
        E: Into<RuntimeSendEffect>,
    {
        let effect = effect.into();
        if let Some(message) = effect.message() {
            return self.dispatch_message_send_effect(message.clone());
        }
        if let Some(pairing) = effect.pairing() {
            return self.dispatch_pairing_transport_effect(pairing.clone());
        }
        Ok(())
    }

    fn dispatch_pairing_transport_effect(&mut self, effect: PairingSendEffect) -> Result<()> {
        if !self.connected {
            return Ok(());
        }
        let ciphertext = match effect.kind {
            PairingSendKind::Offer => effect
                .payload
                .context("runtime pairing offer payload is missing")?,
            PairingSendKind::Rejection => RelayPayloadV1::pairing_rejected(effect.pairing_id)
                .encode()
                .map_err(anyhow::Error::msg)?,
        };
        self.relay_commands
            .try_send(crate::transport::RelayCommand::Send {
                message_id: Uuid::new_v4(),
                recipient: effect.recipient_installation_id,
                ciphertext,
            })
            .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        Ok(())
    }

    fn dispatch_message_send_effect(&mut self, effect: MessageSendEffect) -> Result<()> {
        let message_id =
            Uuid::parse_str(&effect.message_id).context("invalid runtime message ID")?;
        let mut stored = self
            .store
            .message(&effect.message_id)?
            .context("runtime message is missing from desktop store")?;
        let relay_payload = if let Some(existing) = stored.relay_payload.clone() {
            existing
        } else {
            let conversation = self
                .conversations
                .get_mut(&effect.recipient_installation_id)
                .context("kontakt wymaga najpierw wymiany QR")?;
            let plaintext = ApplicationPayloadV1::Message {
                version: torchat_core::PROTOCOL_VERSION,
                message_id,
                sent_at: stored.created_at,
                body: effect.body.clone(),
            }
            .encode()
            .map_err(anyhow::Error::msg)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(anyhow::Error::msg)?;
            let payload = RelayPayloadV1::application(&encrypted)
                .encode()
                .map_err(anyhow::Error::msg)?;
            let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
            let conversation_summary = self
                .store
                .runtime_conversation(&effect.conversation_id)?
                .context("runtime conversation is missing from desktop store")?;
            stored.relay_payload = Some(payload.clone());
            self.store.persist_outbound_encryption(
                &stored,
                &effect.conversation_id,
                &snapshot,
                &conversation_summary,
            )?;
            payload
        };

        if !self.connected {
            self.apply_transport_fact(&effect.message_id, RuntimeTransportFact::RetryableFailure)?;
            return Ok(());
        }

        if self
            .relay_commands
            .try_send(crate::transport::RelayCommand::Send {
                message_id,
                recipient: effect.recipient_installation_id,
                ciphertext: relay_payload,
            })
            .is_err()
        {
            self.apply_transport_fact(&effect.message_id, RuntimeTransportFact::RetryableFailure)?;
            anyhow::bail!("relay actor stopped");
        }

        if self.selected_peer.as_deref() == Some(&effect.conversation_id) {
            self.messages = self.store.messages(&effect.conversation_id)?;
        }
        Ok(())
    }

    fn apply_transport_fact(&mut self, message_id: &str, fact: RuntimeTransportFact) -> Result<()> {
        let outcome: MessageTransportOutcome = fact.into();
        if matches!(fact, RuntimeTransportFact::AcceptedLocally) {
            return Ok(());
        }
        crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "applyMessageTransportOutcome",
            serde_json::json!({
                "messageId": message_id,
                "outcome": outcome,
            }),
        )?;
        Ok(())
    }
}
