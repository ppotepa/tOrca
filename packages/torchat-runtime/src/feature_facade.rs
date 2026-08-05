use crate::{
    ChatMessage, ClientRuntime, ContactRecord, ContactStorage, ConversationStorage,
    ConversationSummary, FeatureResult, MessageStorage, PointLookupStorage, RuntimeClock,
    RuntimeResult, RuntimeTransport,
    features::{
        contacts::ContactsFeature, conversations::ConversationsFeature, messaging::MessagingFeature,
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
    fn feature_mark_conversation_read(
        &mut self,
        conversation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_message_by_id(&mut self, message_id: &str)
        -> RuntimeResult<Option<ChatMessage>>;
    fn feature_save_message(
        &mut self,
        message: ChatMessage,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;
    fn feature_delete_message(&mut self, message_id: &str)
        -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRuntimeFeatureFacade for ClientRuntime<S, T, C>
where
    S: ContactStorage
        + ConversationStorage
        + MessageStorage
        + PointLookupStorage,
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
}
