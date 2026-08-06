use crate::{
    ChangeSet, ConversationState, ConversationStorage, ConversationSummary, FeatureResult,
    PointLookupStorage, RuntimeResult,
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

    pub fn activate_for_contact(
        &mut self,
        installation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ConversationSummary>> {
        let existing = self.storage.conversation_for_contact(installation_id)?;
        let mut conversation = existing.unwrap_or_else(|| ConversationSummary {
            id: installation_id.to_owned(),
            contact_installation_id: installation_id.to_owned(),
            status: ConversationState::Active,
            last_message_preview: "Nowa rozmowa".to_owned(),
            last_message_at: now_ms,
            unread_count: 0,
        });
        if conversation.status == ConversationState::Active {
            return Ok(FeatureResult::unchanged(conversation));
        }
        conversation.status = ConversationState::Active;
        self.save(conversation)
    }

    pub fn mark_read(&mut self, conversation_id: &str) -> RuntimeResult<FeatureResult<()>> {
        self.storage.mark_conversation_read(conversation_id)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::default().with_conversation(conversation_id),
        ))
    }
}
