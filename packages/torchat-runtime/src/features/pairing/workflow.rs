use crate::{
    ChangeSet, ContactStorage, FeatureResult, InviteState, PairingCancelEffect, PairingPeerOutcome,
    PairingPreparation, PairingSendKind, PairingStorage, PointLookupStorage, RuntimeError,
    RuntimeResult, RuntimeSendEffect,
    pairing_rules::{PairingAction, normalize_pairing_item},
};

use super::process;

pub struct PairingFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> PairingFeature<'a, S>
where
    S: PairingStorage + ContactStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn offer_payload(&self, pairing_id: &str) -> RuntimeResult<String> {
        self.require_inbox(pairing_id)?
            .offer_payload
            .ok_or_else(|| RuntimeError::NotFound("pairing offer does not exist".to_owned()))
    }

    pub fn prepare_accept(
        &self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        let item = self.require_inbox(pairing_id)?;
        let sender_id = item
            .sender
            .as_ref()
            .map(|sender| sender.installation_id.as_str())
            .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
        let existing = self.storage.contact_by_installation_id(sender_id)?;
        process::prepare_accept(item, &existing.into_iter().collect::<Vec<_>>(), now_secs)
    }

    pub fn commit_accept(
        &mut self,
        pairing_id: &str,
        offer_invite_id: String,
        offer_payload: String,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>> {
        let item = self.require_inbox(pairing_id)?;
        let (item, effect) =
            process::commit_accept(item, offer_invite_id, offer_payload, now_secs)?;
        self.storage.put_pairing_inbox(item)?;
        Ok(changed(pairing_id, effect))
    }

    pub fn accept_received(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<()>> {
        let item = self.require_inbox(pairing_id)?;
        if matches!(item.state, InviteState::Accepted | InviteState::Completed) {
            return Ok(FeatureResult::unchanged(()));
        }
        let item = process::transition_item(item, PairingAction::Accept)?;
        self.storage.put_pairing_inbox(item)?;
        Ok(changed(pairing_id, ()))
    }

    pub fn prepare_reject(
        &self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        let item = self.require_inbox(pairing_id)?;
        let capability = item.capability.clone().ok_or_else(|| {
            RuntimeError::Conflict("pairing capability does not exist".to_owned())
        })?;
        let (_, recipient_installation_id) = process::prepare_reject(item, now_secs)?;
        Ok(PairingPreparation {
            pairing_id: pairing_id.to_owned(),
            recipient_installation_id,
            capability,
        })
    }

    pub fn commit_reject(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>> {
        let item = self.require_inbox(pairing_id)?;
        let already_rejected = item.state == InviteState::Rejected;
        let (item, recipient_installation_id) = process::prepare_reject(item, now_secs)?;
        if !already_rejected {
            self.storage.put_pairing_inbox(item)?;
        }
        Ok(changed(
            pairing_id,
            process::send_effect(
                pairing_id.to_owned(),
                recipient_installation_id,
                PairingSendKind::Rejection,
                None,
            ),
        ))
    }

    pub fn prepare_cancel(&self, pairing_id: &str) -> RuntimeResult<PairingCancelEffect> {
        process::prepare_cancel(&self.require_outbox(pairing_id)?)
    }

    pub fn confirm_cancelled(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<()>> {
        let item = self.require_outbox(pairing_id)?;
        let Some(item) = process::confirm_cancel(item)? else {
            return Ok(FeatureResult::unchanged(()));
        };
        self.storage.put_pairing_outbox(item)?;
        Ok(changed(pairing_id, ()))
    }

    pub fn archive(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<()>> {
        if let Some(item) = self.storage.pairing_inbox_by_id(pairing_id)? {
            self.storage
                .put_pairing_inbox(process::transition_item(item, PairingAction::Archive)?)?;
            return Ok(changed(pairing_id, ()));
        }
        if let Some(item) = self.storage.pairing_outbox_by_id(pairing_id)? {
            self.storage
                .put_pairing_outbox(process::transition_item(item, PairingAction::Archive)?)?;
            return Ok(changed(pairing_id, ()));
        }
        Err(RuntimeError::NotFound(
            "pairing request does not exist".to_owned(),
        ))
    }

    pub fn finalize(&mut self, pairing_id: &str) -> RuntimeResult<FeatureResult<()>> {
        if let Some(item) = self.storage.pairing_inbox_by_id(pairing_id)? {
            if item.state == InviteState::Completed {
                return Ok(FeatureResult::unchanged(()));
            }
            self.storage
                .put_pairing_inbox(process::transition_item(item, PairingAction::Complete)?)?;
            return Ok(changed(pairing_id, ()));
        }
        let mut item = match self.storage.pairing_outbox_by_id(pairing_id)? {
            Some(item) => item,
            None => return Ok(FeatureResult::unchanged(())),
        };
        if item.state == InviteState::Completed {
            return Ok(FeatureResult::unchanged(()));
        }
        item.state = process::next_state_for_peer_outcome(
            item.state,
            PairingPeerOutcome::WelcomePrepared,
        )?;
        self.storage.put_pairing_outbox(normalize_pairing_item(item))?;
        Ok(changed(pairing_id, ()))
    }

    pub fn apply_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<()>> {
        let mut item = self.require_outbox(pairing_id)?;
        let next_state = process::next_state_for_peer_outcome(item.state, outcome)?;
        if next_state == item.state {
            return Ok(FeatureResult::unchanged(()));
        }
        item.state = next_state;
        self.storage.put_pairing_outbox(normalize_pairing_item(item))?;
        Ok(changed(pairing_id, ()))
    }

    pub fn complete_welcome(
        &mut self,
        pairing_id: &str,
        peer_installation_id: String,
    ) -> RuntimeResult<FeatureResult<()>> {
        let item = self.require_inbox(pairing_id)?;
        let completed = process::complete_welcome(item, peer_installation_id)?;
        if completed.state == InviteState::Completed {
            self.storage.put_pairing_inbox(completed)?;
        }
        Ok(changed(pairing_id, ()))
    }

    fn require_inbox(&self, pairing_id: &str) -> RuntimeResult<crate::PairingItem> {
        self.storage
            .pairing_inbox_by_id(pairing_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))
    }

    fn require_outbox(&self, pairing_id: &str) -> RuntimeResult<crate::PairingItem> {
        self.storage
            .pairing_outbox_by_id(pairing_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing request does not exist".to_owned()))
    }
}

fn changed<T>(pairing_id: &str, value: T) -> FeatureResult<T> {
    FeatureResult::changed(value, ChangeSet::default().with_pairing(pairing_id))
}
