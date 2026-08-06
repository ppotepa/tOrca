use crate::{
    ChangeSet, ContactStorage, FeatureResult, PairingItem, PairingStorage, PointLookupStorage,
    ProfileStorage, RuntimeError, RuntimeResult,
};

use super::process;

#[derive(Debug, Clone)]
pub struct ReceivedPairingOffer {
    pub item: PairingItem,
    pub inserted: bool,
}

pub fn receive_offer<S>(
    storage: &mut S,
    remote: PairingItem,
    now_secs: i64,
) -> RuntimeResult<FeatureResult<ReceivedPairingOffer>>
where
    S: PairingStorage + ProfileStorage + ContactStorage + PointLookupStorage,
{
    let mut local = storage.pairing_inbox()?;
    let mut changes = ChangeSet::none();
    for expired in process::expire_items(&mut local, now_secs) {
        changes = changes.with_pairing(expired.pairing_id.clone());
        storage.put_pairing_inbox(expired)?;
    }

    let merge = process::merge_remote_items(&mut local, vec![remote])
        .into_iter()
        .next()
        .ok_or_else(|| RuntimeError::Storage("pairing offer merge produced no result".to_owned()))?;
    if merge.inserted || merge.changed {
        changes = changes.with_pairing(merge.item.pairing_id.clone());
        storage.put_pairing_inbox(merge.item.clone())?;
    }
    let value = ReceivedPairingOffer {
        item: merge.item,
        inserted: merge.inserted,
    };
    if changes.sections.is_empty() {
        Ok(FeatureResult::unchanged(value))
    } else {
        Ok(FeatureResult::changed(value, changes))
    }
}
