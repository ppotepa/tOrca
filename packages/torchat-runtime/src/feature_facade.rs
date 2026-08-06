use crate::{
    CapabilityStorage, ChatMessage, ClientRuntime, ContactRecord, ContactStorage,
    ContactTransportPolicy, ConversationStorage, ConversationSummary, FeatureResult, InviteState,
    MessageStorage, PairingCancelEffect, PairingPeerOutcome, PairingPreparation, PairingStorage,
    PointLookupStorage, ReceiptSendEffect, ReceiptStorage, RelationshipStorage,
    RelationshipTransition, RuntimeClock, RuntimeError, RuntimeEvent, RuntimeResult,
    RuntimeSendEffect, RuntimeStorage, RuntimeTransport,
    features::{
        contacts::ContactsFeature, conversations::ConversationsFeature, messaging::MessagingFeature,
        pairing::PairingFeature, peer::PeerFeature, presence::PresenceFeature,
        receipts::ReceiptsFeature, relationships::RelationshipsFeature,
    },
};

/// Narrow, capability-based entry point for domain features.
///
/// Existing `ClientRuntime` methods remain source-compatible during migration,
/// but new engine code should use this facade so each operation only sees the
/// storage capabilities it actually needs.
pub trait ClientRuntimeFeatureFacade {
    fn feature_contact_by_id(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>>;
    fn feature_save_contact(
        &mut self,
        contact: ContactRecord,
    ) -> RuntimeResult<FeatureResult<ContactRecord>>;
    fn feature_update_contact_settings(
        &mut self,
        installation_id: &str,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
        transport_policy: Option<ContactTransportPolicy>,
    ) -> RuntimeResult<FeatureResult<ContactRecord>>;
    fn feature_verify_contact(
        &mut self,
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_conversation_by_id(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>>;
    fn feature_conversation_for_contact(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>>;
    fn feature_save_conversation(
        &mut self,
        conversation: ConversationSummary,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>>;
    fn feature_start_conversation(
        &mut self,
        contact_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<bool>>;
    fn feature_mark_conversation_read(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_message_by_id(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<Option<ChatMessage>>;
    fn feature_save_message(
        &mut self,
        message: ChatMessage,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;
    fn feature_delete_message(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_prepare_accept_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation>;
    fn feature_pairing_offer_payload(&mut self, pairing_id: &str) -> RuntimeResult<String>;
    fn feature_accept_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>>;
    fn feature_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<(RuntimeSendEffect, InviteState)>>;
    fn feature_archive_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>>;
    fn feature_prepare_cancel_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<PairingCancelEffect>;
    fn feature_confirm_pairing_cancelled(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>>;
    fn feature_apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<InviteState>>;
    fn feature_apply_relationship(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>>;
    fn feature_publish_presence(&mut self, event: RuntimeEvent) -> FeatureResult<()>;
    fn feature_store_peer_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_revoke_peer_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRuntimeFeatureFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage
        + ContactStorage
        + ConversationStorage
        + MessageStorage
        + PairingStorage
        + PointLookupStorage
        + RelationshipStorage
        + ReceiptStorage
        + CapabilityStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_contact_by_id(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        ContactsFeature::new(self.storage_mut()).by_installation_id(installation_id)
    }

    fn feature_save_contact(
        &mut self,
        contact: ContactRecord,
    ) -> RuntimeResult<FeatureResult<ContactRecord>> {
        ContactsFeature::new(self.storage_mut()).save(contact)
    }

    fn feature_update_contact_settings(
        &mut self,
        installation_id: &str,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
        transport_policy: Option<ContactTransportPolicy>,
    ) -> RuntimeResult<FeatureResult<ContactRecord>> {
        let result = ContactsFeature::new(self.storage_mut()).update_settings(
            installation_id,
            local_alias,
            muted,
            blocked,
            transport_policy,
        )?;
        if !result.changes.sections.is_empty() {
            self.session_mut().push_event(RuntimeEvent::Changed {
                kind: Some("contacts".to_owned()),
            });
        }
        Ok(result)
    }

    fn feature_verify_contact(
        &mut self,
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        let contact_result = ContactsFeature::new(self.storage_mut()).verify(installation_id)?;
        let conversation_result =
            ConversationsFeature::new(self.storage_mut()).activate_for_contact(installation_id, now_ms)?;
        let mut changes = contact_result.changes;
        changes.merge(conversation_result.changes);
        if changes.sections.is_empty() {
            return Ok(FeatureResult::unchanged(()));
        }
        self.session_mut().push_event(RuntimeEvent::Changed {
            kind: Some("contacts".to_owned()),
        });
        self.session_mut().push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(FeatureResult::changed((), changes))
    }

    fn feature_conversation_by_id(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        ConversationsFeature::new(self.storage_mut()).by_id(conversation_id)
    }

    fn feature_conversation_for_contact(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        ConversationsFeature::new(self.storage_mut()).for_contact(installation_id)
    }

    fn feature_save_conversation(
        &mut self,
        conversation: ConversationSummary,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        ConversationsFeature::new(self.storage_mut()).save(conversation)
    }

    fn feature_start_conversation(
        &mut self,
        contact_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<bool>> {
        ContactsFeature::new(self.storage_mut())
            .by_installation_id(contact_id)?
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        let conversation =
            ConversationsFeature::new(self.storage_mut()).activate_for_contact(contact_id, now_ms)?;
        if conversation.changes.sections.is_empty() {
            return Ok(FeatureResult::unchanged(true));
        }
        self.session_mut().push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        Ok(FeatureResult::changed(true, conversation.changes))
    }

    fn feature_mark_conversation_read(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        ConversationsFeature::new(self.storage_mut()).mark_read(conversation_id)
    }

    fn feature_message_by_id(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<Option<ChatMessage>> {
        MessagingFeature::new(self.storage_mut()).by_id(message_id)
    }

    fn feature_save_message(
        &mut self,
        message: ChatMessage,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        MessagingFeature::new(self.storage_mut()).save(message)
    }

    fn feature_delete_message(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        MessagingFeature::new(self.storage_mut()).delete(message_id)
    }

    fn feature_prepare_accept_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        PairingFeature::new(self.storage_mut()).prepare_accept(pairing_id, now_secs)
    }

    fn feature_pairing_offer_payload(&mut self, pairing_id: &str) -> RuntimeResult<String> {
        PairingFeature::new(self.storage_mut()).offer_payload(pairing_id)
    }

    fn feature_accept_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let result = PairingFeature::new(self.storage_mut()).accept(pairing_id)?;
        if !result.changes.sections.is_empty() {
            self.session_mut().push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(result.value),
            });
        }
        Ok(result)
    }

    fn feature_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<(RuntimeSendEffect, InviteState)>> {
        let result = PairingFeature::new(self.storage_mut()).reject(pairing_id, now_secs)?;
        if !result.changes.sections.is_empty() {
            self.session_mut().push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(result.value.1),
            });
        }
        Ok(result)
    }

    fn feature_archive_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let result = PairingFeature::new(self.storage_mut()).archive(pairing_id)?;
        self.session_mut().push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: Some(pairing_id.to_owned()),
            state: Some(result.value),
        });
        Ok(result)
    }

    fn feature_prepare_cancel_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<PairingCancelEffect> {
        PairingFeature::new(self.storage_mut()).prepare_cancel(pairing_id)
    }

    fn feature_confirm_pairing_cancelled(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let result = PairingFeature::new(self.storage_mut()).confirm_cancel(pairing_id)?;
        if !result.changes.sections.is_empty() {
            self.session_mut().push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(result.value),
            });
        }
        Ok(result)
    }

    fn feature_apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let result = PairingFeature::new(self.storage_mut()).apply_peer_outcome(pairing_id, outcome)?;
        if !result.changes.sections.is_empty() {
            self.session_mut().push_event(RuntimeEvent::InviteStateChanged {
                pairing_id: Some(pairing_id.to_owned()),
                state: Some(result.value),
            });
        }
        Ok(result)
    }

    fn feature_apply_relationship(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<FeatureResult<()>> {
        RelationshipsFeature::new(self.storage_mut()).apply(transition)
    }

    fn feature_pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        ReceiptsFeature::new(self.storage()).pending()
    }

    fn feature_publish_presence(&mut self, event: RuntimeEvent) -> FeatureResult<()> {
        PresenceFeature::new(self.session_mut()).publish(event)
    }

    fn feature_store_peer_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<FeatureResult<()>> {
        PeerFeature::new(self.storage_mut()).store_capability(
            contact_installation_id,
            capability_id,
            secret,
            sequence,
            issued_at,
            expires_at,
        )
    }

    fn feature_revoke_peer_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        PeerFeature::new(self.storage_mut()).revoke_capability(contact_installation_id)
    }
}
