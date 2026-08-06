use crate::{
    ChangeSet, ContactRecord, ConversationState, ConversationStorage, ConversationSummary,
    FeatureResult, PointLookupStorage, RuntimeError, RuntimeResult,
};

pub struct ConversationsFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> ConversationsFeature<'a, S>
where
    S: ConversationStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn by_id(&self, conversation_id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        self.storage.conversation_by_id(conversation_id)
    }

    pub fn require(&self, conversation_id: &str) -> RuntimeResult<ConversationSummary> {
        self.by_id(conversation_id)?
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))
    }

    pub fn for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        self.storage.conversation_for_contact(installation_id)
    }

    pub fn save(
        &mut self,
        conversation: ConversationSummary,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        self.storage.put_conversation(conversation.clone())?;
        let changes = ChangeSet::default().with_conversation(conversation.id.clone());
        Ok(FeatureResult::changed(conversation, changes))
    }

    pub fn ensure_for_contact(
        &mut self,
        contact: &ContactRecord,
        status: ConversationState,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        let mut conversation = self
            .for_contact(&contact.installation_id)?
            .unwrap_or_else(|| ConversationSummary {
                id: contact.installation_id.clone(),
                contact_installation_id: contact.installation_id.clone(),
                status,
                last_message_preview: String::new(),
                last_message_at: now_ms,
                unread_count: 0,
            });
        conversation.status = status;
        self.save(conversation)
    }

    pub fn mark_read(&mut self, conversation_id: &str) -> RuntimeResult<FeatureResult<()>> {
        self.require(conversation_id)?;
        self.storage.mark_conversation_read(conversation_id)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::default().with_conversation(conversation_id),
        ))
    }
}
