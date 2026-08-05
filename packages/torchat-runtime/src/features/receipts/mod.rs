use crate::{ChangeSections, ChangeSet, FeatureResult, ReceiptSendEffect, ReceiptStorage, RuntimeResult};

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
        self.storage.pending_receipts()
    }

    pub fn changed() -> FeatureResult<()> {
        FeatureResult::changed(
            (),
            ChangeSet::section(ChangeSections::RECEIPTS),
        )
    }
}
