use crate::{
    ChangeSections, ChangeSet, FeatureResult, ReceiptSendEffect, ReceiptStorage, RuntimeError,
    RuntimeResult,
};

pub struct ReceiptsFeature<'a, S> {
    storage: &'a S,
}

impl<'a, S> ReceiptsFeature<'a, S>
where
    S: ReceiptStorage,
{
    pub fn new(storage: &'a S) -> Self {
        Self { storage }
    }

    pub fn pending(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        self.storage
            .pending_receipts()?
            .into_iter()
            .map(validate_effect)
            .collect()
    }

    pub fn changed() -> FeatureResult<()> {
        FeatureResult::changed(
            (),
            ChangeSet::section(ChangeSections::RECEIPTS),
        )
    }
}

fn validate_effect(effect: ReceiptSendEffect) -> RuntimeResult<ReceiptSendEffect> {
    if effect.envelope_id.trim().is_empty()
        || effect.message_id.trim().is_empty()
        || effect.conversation_id.trim().is_empty()
        || effect.recipient_installation_id.trim().is_empty()
    {
        return Err(RuntimeError::Storage(
            "durable receipt contains an empty identity".to_owned(),
        ));
    }
    if effect.received_at < 0 {
        return Err(RuntimeError::Storage(
            "durable receipt timestamp must not be negative".to_owned(),
        ));
    }
    Ok(effect)
}
