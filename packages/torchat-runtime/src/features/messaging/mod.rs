use crate::{
    ChangeSet, ChatMessage, FeatureResult, MessageStorage, PointLookupStorage, RuntimeResult,
};

pub struct MessagingFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> MessagingFeature<'a, S>
where
    S: MessageStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.storage.message_by_id(message_id)
    }

    pub fn save(&mut self, message: ChatMessage) -> RuntimeResult<FeatureResult<ChatMessage>> {
        self.storage.put_message(message.clone())?;
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(message, changes))
    }

    pub fn delete(&mut self, message_id: &str) -> RuntimeResult<FeatureResult<()>> {
        let conversation_id = self
            .storage
            .message_by_id(message_id)?
            .map(|message| message.conversation_id);
        self.storage.delete_message(message_id)?;
        let mut changes = ChangeSet::default().with_message(message_id);
        if let Some(conversation_id) = conversation_id {
            changes = changes.with_conversation(conversation_id);
        }
        Ok(FeatureResult::changed((), changes))
    }
}
