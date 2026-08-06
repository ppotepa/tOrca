use crate::{
    ChangeSet, ClientRuntime, ConversationState, ConversationStorage, ConversationSummary,
    FeatureResult, PointLookupStorage, RuntimeClock, RuntimeEvent, RuntimeResult, RuntimeStorage,
    RuntimeTransport,
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

    pub fn for_contact(&self, installation_id: &str) -> RuntimeResult<Option<ConversationSummary>> {
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
        match self.storage.conversation_for_contact(installation_id)? {
            Some(conversation) if conversation.status == ConversationState::Active => {
                Ok(FeatureResult::unchanged(conversation))
            }
            Some(mut conversation) => {
                conversation.status = ConversationState::Active;
                self.save(conversation)
            }
            None => self.save(ConversationSummary {
                id: installation_id.to_owned(),
                contact_installation_id: installation_id.to_owned(),
                status: ConversationState::Active,
                last_message_preview: "Nowa rozmowa".to_owned(),
                last_message_at: now_ms,
                unread_count: 0,
            }),
        }
    }

    pub fn mark_read(&mut self, conversation_id: &str) -> RuntimeResult<FeatureResult<()>> {
        self.storage.mark_conversation_read(conversation_id)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::default().with_conversation(conversation_id),
        ))
    }
}

pub trait ClientRuntimeConversationFacade {
    fn feature_set_conversation_focus(
        &mut self,
        conversation_id: &str,
        focused: bool,
    ) -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRuntimeConversationFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage + ConversationStorage + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_set_conversation_focus(
        &mut self,
        conversation_id: &str,
        focused: bool,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.session_mut()
            .set_conversation_focus(conversation_id, focused);
        if !focused || !self.session().conversation_is_attended(conversation_id) {
            return Ok(FeatureResult::unchanged(()));
        }
        let conversation = ConversationsFeature::new(self.storage_mut()).by_id(conversation_id)?;
        let Some(conversation) = conversation else {
            return Ok(FeatureResult::unchanged(()));
        };
        if conversation.unread_count == 0 {
            return Ok(FeatureResult::unchanged(()));
        }
        let result = ConversationsFeature::new(self.storage_mut()).mark_read(conversation_id)?;
        self.session_mut()
            .push_event(RuntimeEvent::ConversationReadChanged {
                conversation_id: Some(conversation_id.to_owned()),
                unread_count: Some(0),
            });
        Ok(result)
    }
}
