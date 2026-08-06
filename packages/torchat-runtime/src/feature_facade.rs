use crate::{
    CapabilityStorage, ChangeSections, ChangeSet, ChatMessage, ClientRuntime, ContactRecord,
    ContactStorage, ContactTransportPolicy, ConversationState, ConversationStorage,
    ConversationSummary, FeatureResult, MessageReply, MessageSendEffect, MessageStorage,
    MessageTransportOutcome, PointLookupStorage, ReceiptSendEffect, ReceiptStorage,
    RelationshipStorage, RelationshipTransition, RuntimeClock, RuntimeEvent, RuntimeResult,
    RuntimeSession, RuntimeStorage, RuntimeTransport,
    features::{
        contacts::ContactsFeature, conversations::ConversationsFeature, messaging::MessagingFeature,
        peer::PeerFeature, presence::PresenceFeature, receipts::ReceiptsFeature,
        relationships::RelationshipsFeature,
    },
};

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
    ) -> RuntimeResult<FeatureResult<ConversationSummary>>;
    fn feature_promote_verified_contact(
        &mut self,
        contact: ContactRecord,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>>;
    fn feature_contact_accepts_messages(&mut self, installation_id: &str) -> RuntimeResult<bool>;
    fn feature_contact_allows_notifications(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<bool>;
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
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>>;
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
    fn feature_queue_message(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>>;
    fn feature_retry_message(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>>;
    fn feature_apply_message_read(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;
    fn feature_apply_message_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;
    fn feature_receive_message(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<uuid::Uuid>,
        reply_to: Option<MessageReply>,
        attended: bool,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;
    fn feature_pending_message_sends(&mut self) -> RuntimeResult<Vec<MessageSendEffect>>;
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
        let result = ContactsFeature::new(self.storage_mut()).save(contact)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
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
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_verify_contact(
        &mut self,
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        let contact_result = ContactsFeature::new(self.storage_mut()).verify(installation_id)?;
        let conversation_result = ConversationsFeature::new(self.storage_mut()).ensure_for_contact(
            &contact_result.value,
            ConversationState::Active,
            now_ms,
        )?;
        let mut changes = contact_result.changes;
        changes.merge(conversation_result.changes);
        publish_changes(self.session_mut(), &changes);
        Ok(FeatureResult::changed(conversation_result.value, changes))
    }

    fn feature_promote_verified_contact(
        &mut self,
        contact: ContactRecord,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        let contact_result = ContactsFeature::new(self.storage_mut()).promote_verified(contact)?;
        let conversation_result = ConversationsFeature::new(self.storage_mut()).ensure_for_contact(
            &contact_result.value,
            ConversationState::Active,
            now_ms,
        )?;
        let mut changes = contact_result.changes;
        changes.merge(conversation_result.changes);
        publish_changes(self.session_mut(), &changes);
        Ok(FeatureResult::changed(conversation_result.value, changes))
    }

    fn feature_contact_accepts_messages(&mut self, installation_id: &str) -> RuntimeResult<bool> {
        ContactsFeature::new(self.storage_mut()).accepts_messages(installation_id)
    }

    fn feature_contact_allows_notifications(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<bool> {
        ContactsFeature::new(self.storage_mut()).allows_notifications(installation_id)
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
        let result = ConversationsFeature::new(self.storage_mut()).save(conversation)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_start_conversation(
        &mut self,
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        let contact = ContactsFeature::new(self.storage_mut()).require(installation_id)?;
        let result = ConversationsFeature::new(self.storage_mut()).ensure_for_contact(
            &contact,
            ConversationState::Active,
            now_ms,
        )?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_mark_conversation_read(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = ConversationsFeature::new(self.storage_mut()).mark_read(conversation_id)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
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
        let result = MessagingFeature::new(self.storage_mut()).save(message)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_delete_message(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = MessagingFeature::new(self.storage_mut()).delete(message_id)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_queue_message(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let result = MessagingFeature::new(self.storage_mut()).queue_outgoing(
            conversation_id,
            text,
            reply_to_message_id,
            now_ms,
        )?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_retry_message(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let result = MessagingFeature::new(self.storage_mut()).retry(message_id, now_ms)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_apply_message_read(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let result = MessagingFeature::new(self.storage_mut()).apply_read(message_id)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_apply_message_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let result = MessagingFeature::new(self.storage_mut())
            .apply_transport_outcome(message_id, outcome)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_receive_message(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<uuid::Uuid>,
        reply_to: Option<MessageReply>,
        attended: bool,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let result = MessagingFeature::new(self.storage_mut()).receive(
            conversation_id,
            body,
            message_id,
            reply_to,
            attended,
            now_ms,
        )?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_pending_message_sends(&mut self) -> RuntimeResult<Vec<MessageSendEffect>> {
        let effects = MessagingFeature::new(self.storage_mut()).pending_send_effects()?;
        if !effects.is_empty() {
            self.session_mut().push_event(RuntimeEvent::Changed {
                kind: Some("messages".to_owned()),
            });
        }
        Ok(effects)
    }

    fn feature_apply_relationship(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = RelationshipsFeature::new(self.storage_mut()).apply(transition)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
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
        let result = PeerFeature::new(self.storage_mut()).store_capability(
            contact_installation_id,
            capability_id,
            secret,
            sequence,
            issued_at,
            expires_at,
        )?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }

    fn feature_revoke_peer_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PeerFeature::new(self.storage_mut()).revoke_capability(contact_installation_id)?;
        publish_changes(self.session_mut(), &result.changes);
        Ok(result)
    }
}

fn publish_changes(session: &mut RuntimeSession, changes: &ChangeSet) {
    for (section, kind) in [
        (ChangeSections::PROFILE, "profile"),
        (ChangeSections::PAIRINGS, "pairings"),
        (ChangeSections::CONTACTS, "contacts"),
        (ChangeSections::RELATIONSHIPS, "relationships"),
        (ChangeSections::CONVERSATIONS, "conversations"),
        (ChangeSections::MESSAGES, "messages"),
        (ChangeSections::RECEIPTS, "receipts"),
        (ChangeSections::PRESENCE, "presence"),
        (ChangeSections::TRANSPORT, "transport"),
        (ChangeSections::CAPABILITIES, "capabilities"),
        (ChangeSections::OPERATIONS, "operations"),
    ] {
        if changes.sections.contains(section) {
            session.push_event(RuntimeEvent::Changed {
                kind: Some(kind.to_owned()),
            });
        }
    }
}
