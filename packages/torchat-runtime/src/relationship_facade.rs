use crate::{
    ClientRuntime, FeatureResult, PointLookupStorage, RelationshipStorage, RuntimeClock,
    RuntimeEvent, RuntimeResult, RuntimeTransport,
    features::relationships::{RelationshipRemoval, RelationshipsFeature},
};

pub trait ClientRelationshipFeatureFacade {
    fn feature_request_relationship_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> RuntimeResult<FeatureResult<RelationshipRemoval>>;
    fn feature_apply_remote_relationship_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<FeatureResult<()>>;
    fn feature_begin_verified_relationship(
        &mut self,
        installation_id: &str,
        boundary_at: i64,
    ) -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRelationshipFeatureFacade for ClientRuntime<S, T, C>
where
    S: RelationshipStorage + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_request_relationship_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> RuntimeResult<FeatureResult<RelationshipRemoval>> {
        let result = RelationshipsFeature::new(self.storage_mut()).request_removal(
            installation_id,
            removed_at,
            preserve_history,
        )?;
        publish(self, installation_id);
        Ok(result)
    }

    fn feature_apply_remote_relationship_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = RelationshipsFeature::new(self.storage_mut()).apply_remote_removal(
            installation_id,
            removed_at,
            removal_id,
            relationship_epoch,
        )?;
        publish(self, installation_id);
        Ok(result)
    }

    fn feature_begin_verified_relationship(
        &mut self,
        installation_id: &str,
        boundary_at: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = RelationshipsFeature::new(self.storage_mut())
            .begin_verified(installation_id, boundary_at)?;
        publish(self, installation_id);
        Ok(result)
    }
}

fn publish<S, T, C>(runtime: &mut ClientRuntime<S, T, C>, installation_id: &str)
where
    S: RelationshipStorage + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    for kind in ["relationships", "contacts", "conversations", "messages"] {
        runtime.session_mut().push_event(RuntimeEvent::Changed {
            kind: Some(kind.to_owned()),
        });
    }
    runtime.session_mut().push_event(RuntimeEvent::PeerConnectionChanged {
        installation_id: installation_id.to_owned(),
        status: crate::PeerConnectionStatus::Offline,
    });
}
