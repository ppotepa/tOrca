pub(crate) mod process;
pub mod rules;

pub use crate::point_lookup_storage::PointLookupStorage;
pub use crate::storage_capabilities::PairingStorage;

use crate::pairing_rules::{PairingAction, normalize_pairing_item};
use crate::{
    ChangeSet, ContactRecord, FeatureResult, InviteState, PairingCancelEffect, PairingItem,
    PairingPeerOutcome, PairingPreparation, RuntimeError, RuntimeResult, RuntimeSendEffect,
};

/// Capability-based pairing service.
///
/// The service owns point reads, state transitions and persistence for pairing
/// commands. Transport execution and event publication remain outside this
/// boundary so effects are scheduled only after the surrounding transaction
/// commits.
pub struct PairingFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> PairingFeature<'a, S>
where
    S: PairingStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn prepare_accept(
        &self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        let item = self.inbox_required(pairing_id)?;
        let sender_id = item
            .sender
            .as_ref()
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?
            .installation_id
            .clone();
        let existing_contact = self.storage.contact_by_installation_id(&sender_id)?;
        let contacts = existing_contact.into_iter().collect::<Vec<ContactRecord>>();
        process::prepare_accept(item, &contacts, now_secs)
    }

    pub fn offer_payload(&self, pairing_id: &str) -> RuntimeResult<String> {
        self.inbox_required(pairing_id)?
            .offer_payload
            .ok_or_else(|| RuntimeError::NotFound("pairing offer does not exist".to_owned()))
    }

    pub fn accept(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<InviteState>> {
        let item = self.inbox_required(pairing_id)?;
        if matches!(item.state, InviteState::Accepted | InviteState::Completed) {
            return Ok(FeatureResult::unchanged(item.state));
        }
        let item = process::transition_item(item, PairingAction::Accept)?;
        let state = item.state;
        self.storage.put_pairing_inbox(item)?;
        Ok(FeatureResult::changed(
            state,
            ChangeSet::default().with_pairing(pairing_id),
        ))
    }

    pub fn reject(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<(RuntimeSendEffect, InviteState)>> {
        let item = self.inbox_required(pairing_id)?;
        let already_rejected = item.state == InviteState::Rejected;
        let (updated_item, recipient_installation_id) = process::prepare_reject(item, now_secs)?;
        let state = updated_item.state;
        if !already_rejected {
            self.storage.put_pairing_inbox(updated_item)?;
        }
        let effect = process::send_effect(
            pairing_id.to_owned(),
            recipient_installation_id,
            crate::PairingSendKind::Rejection,
            None,
        );
        let value = (effect, state);
        if already_rejected {
            Ok(FeatureResult::unchanged(value))
        } else {
            Ok(FeatureResult::changed(
                value,
                ChangeSet::default().with_pairing(pairing_id),
            ))
        }
    }

    pub fn archive(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<InviteState>> {
        if let Some(item) = self.storage.pairing_inbox_by_id(pairing_id)? {
            let item = process::transition_item(item, PairingAction::Archive)?;
            let state = item.state;
            self.storage.put_pairing_inbox(item)?;
            return Ok(FeatureResult::changed(
                state,
                ChangeSet::default().with_pairing(pairing_id),
            ));
        }
        let item = self
            .storage
            .pairing_outbox_by_id(pairing_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))?;
        let item = process::transition_item(item, PairingAction::Archive)?;
        let state = item.state;
        self.storage.put_pairing_outbox(item)?;
        Ok(FeatureResult::changed(
            state,
            ChangeSet::default().with_pairing(pairing_id),
        ))
    }

    pub fn prepare_cancel(&self, pairing_id: &str) -> RuntimeResult<PairingCancelEffect> {
        let item = self.outbox_required(pairing_id)?;
        process::prepare_cancel(&item)
    }

    pub fn confirm_cancel(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let item = self.outbox_required(pairing_id)?;
        let Some(item) = process::confirm_cancel(item)? else {
            return Ok(FeatureResult::unchanged(InviteState::Cancelled));
        };
        let state = item.state;
        self.storage.put_pairing_outbox(item)?;
        Ok(FeatureResult::changed(
            state,
            ChangeSet::default().with_pairing(pairing_id),
        ))
    }

    pub fn apply_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<InviteState>> {
        let mut item = self.outbox_required(pairing_id)?;
        let next_state = process::next_state_for_peer_outcome(item.state, outcome)?;
        if item.state == next_state {
            return Ok(FeatureResult::unchanged(next_state));
        }
        item.state = next_state;
        item = normalize_pairing_item(item);
        self.storage.put_pairing_outbox(item)?;
        Ok(FeatureResult::changed(
            next_state,
            ChangeSet::default().with_pairing(pairing_id),
        ))
    }

    pub fn pending_send_effects(&self, now_secs: i64) -> RuntimeResult<Vec<RuntimeSendEffect>> {
        process::pending_send_effects(self.storage.pairing_inbox()?, now_secs)
    }

    fn inbox_required(&self, pairing_id: &str) -> RuntimeResult<PairingItem> {
        self.storage
            .pairing_inbox_by_id(pairing_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))
    }

    fn outbox_required(&self, pairing_id: &str) -> RuntimeResult<PairingItem> {
        self.storage
            .pairing_outbox_by_id(pairing_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))
    }
}
