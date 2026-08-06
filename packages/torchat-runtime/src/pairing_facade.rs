use crate::{
    ClientRuntime, ContactStorage, FeatureResult, InviteCode, PairingCancelEffect, PairingItem,
    PairingPeerOutcome, PairingPreparation, PairingStorage, PointLookupStorage, ProfileStorage,
    RuntimeClock, RuntimeEvent, RuntimeResult, RuntimeSendEffect, RuntimeStorage, RuntimeTransport,
    features::pairing::PairingFeature,
};

pub trait ClientPairingFeatureFacade {
    fn feature_prepare_pairing_code_refresh(&mut self) -> RuntimeResult<()>;
    fn feature_commit_pairing_code(
        &mut self,
        code: InviteCode,
    ) -> RuntimeResult<FeatureResult<InviteCode>>;
    fn feature_prepare_submit_pairing_code(
        &mut self,
        code: String,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<String>>;
    fn feature_commit_submitted_pairing(
        &mut self,
        item: PairingItem,
    ) -> RuntimeResult<FeatureResult<PairingItem>>;
    fn feature_pending_pairing_send_effects(
        &mut self,
        now_secs: i64,
    ) -> RuntimeResult<Vec<RuntimeSendEffect>>;
    fn feature_reconcile_outbox_pairing_contact(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<FeatureResult<Vec<String>>>;
    fn feature_pairing_offer_payload(&mut self, pairing_id: &str) -> RuntimeResult<String>;
    fn feature_prepare_accept_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation>;
    fn feature_commit_accept_pairing(
        &mut self,
        pairing_id: &str,
        offer_invite_id: String,
        offer_payload: String,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>>;
    fn feature_accept_received_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_prepare_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation>;
    fn feature_commit_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>>;
    fn feature_prepare_cancel_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<PairingCancelEffect>;
    fn feature_confirm_pairing_cancelled(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_archive_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_finalize_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_complete_pairing_welcome(
        &mut self,
        pairing_id: &str,
        peer_installation_id: String,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_complete_pairing_welcome_for_offer_invite(
        &mut self,
        offer_invite_id: &str,
        peer_installation_id: String,
    ) -> RuntimeResult<FeatureResult<String>>;
}

impl<S, T, C> ClientPairingFeatureFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage
        + PairingStorage
        + ProfileStorage
        + ContactStorage
        + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_prepare_pairing_code_refresh(&mut self) -> RuntimeResult<()> {
        PairingFeature::new(self.storage_mut()).prepare_refresh_code()
    }

    fn feature_commit_pairing_code(
        &mut self,
        code: InviteCode,
    ) -> RuntimeResult<FeatureResult<InviteCode>> {
        let result = PairingFeature::new(self.storage_mut()).commit_code(code)?;
        publish_pairing_change(self, None, &result);
        Ok(result)
    }

    fn feature_prepare_submit_pairing_code(
        &mut self,
        code: String,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<String>> {
        let result = PairingFeature::new(self.storage_mut()).prepare_submit_code(code, now_secs)?;
        publish_pairing_change(self, None, &result);
        Ok(result)
    }

    fn feature_commit_submitted_pairing(
        &mut self,
        item: PairingItem,
    ) -> RuntimeResult<FeatureResult<PairingItem>> {
        let pairing_id = item.pairing_id.clone();
        let result = PairingFeature::new(self.storage_mut()).commit_submitted(item)?;
        publish_pairing_change(self, Some(&pairing_id), &result);
        Ok(result)
    }

    fn feature_pending_pairing_send_effects(
        &mut self,
        now_secs: i64,
    ) -> RuntimeResult<Vec<RuntimeSendEffect>> {
        PairingFeature::new(self.storage_mut()).pending_send_effects(now_secs)
    }

    fn feature_reconcile_outbox_pairing_contact(
        &mut self,
        installation_id: &str,
    ) -> RuntimeResult<FeatureResult<Vec<String>>> {
        let result = PairingFeature::new(self.storage_mut())
            .reconcile_outbox_contact(installation_id)?;
        for pairing_id in &result.value {
            publish_pairing_change(self, Some(pairing_id), &result);
        }
        Ok(result)
    }

    fn feature_pairing_offer_payload(&mut self, pairing_id: &str) -> RuntimeResult<String> {
        PairingFeature::new(self.storage_mut()).offer_payload(pairing_id)
    }

    fn feature_prepare_accept_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        PairingFeature::new(self.storage_mut()).prepare_accept(pairing_id, now_secs)
    }

    fn feature_commit_accept_pairing(
        &mut self,
        pairing_id: &str,
        offer_invite_id: String,
        offer_payload: String,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>> {
        let result = PairingFeature::new(self.storage_mut()).commit_accept(
            pairing_id,
            offer_invite_id,
            offer_payload,
            now_secs,
        )?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_accept_received_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut()).accept_received(pairing_id)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_prepare_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<PairingPreparation> {
        PairingFeature::new(self.storage_mut()).prepare_reject(pairing_id, now_secs)
    }

    fn feature_commit_reject_pairing(
        &mut self,
        pairing_id: &str,
        now_secs: i64,
    ) -> RuntimeResult<FeatureResult<RuntimeSendEffect>> {
        let result =
            PairingFeature::new(self.storage_mut()).commit_reject(pairing_id, now_secs)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_prepare_cancel_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<PairingCancelEffect> {
        PairingFeature::new(self.storage_mut()).prepare_cancel(pairing_id)
    }

    fn feature_confirm_pairing_cancelled(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut()).confirm_cancelled(pairing_id)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_archive_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut()).archive(pairing_id)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_finalize_pairing(
        &mut self,
        pairing_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut()).finalize(pairing_id)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut()).apply_peer_outcome(pairing_id, outcome)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_complete_pairing_welcome(
        &mut self,
        pairing_id: &str,
        peer_installation_id: String,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = PairingFeature::new(self.storage_mut())
            .complete_welcome(pairing_id, peer_installation_id)?;
        publish_pairing_change(self, Some(pairing_id), &result);
        Ok(result)
    }

    fn feature_complete_pairing_welcome_for_offer_invite(
        &mut self,
        offer_invite_id: &str,
        peer_installation_id: String,
    ) -> RuntimeResult<FeatureResult<String>> {
        let result = PairingFeature::new(self.storage_mut())
            .complete_welcome_for_offer_invite(offer_invite_id, peer_installation_id)?;
        let pairing_id = result.value.clone();
        publish_pairing_change(self, Some(&pairing_id), &result);
        Ok(result)
    }
}

fn publish_pairing_change<S, T, C, V>(
    runtime: &mut ClientRuntime<S, T, C>,
    pairing_id: Option<&str>,
    result: &FeatureResult<V>,
) where
    S: RuntimeStorage
        + PairingStorage
        + ProfileStorage
        + ContactStorage
        + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    if !result.changes.sections.is_empty() {
        runtime.session_mut().push_event(RuntimeEvent::InviteStateChanged {
            pairing_id: pairing_id.map(str::to_owned),
            state: None,
        });
    }
}
