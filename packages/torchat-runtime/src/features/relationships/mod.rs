use crate::{
    ChangeSections, ChangeSet, FeatureResult, RelationshipStorage, RelationshipTransition,
    RuntimeError, RuntimeResult,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipRemoval {
    pub removal_id: String,
    pub relationship_epoch: i64,
}

pub struct RelationshipsFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> RelationshipsFeature<'a, S>
where
    S: RelationshipStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn request_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> RuntimeResult<FeatureResult<RelationshipRemoval>> {
        if installation_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "contact installation id must not be empty".to_owned(),
            ));
        }
        let removal_id = uuid::Uuid::new_v4().to_string();
        let relationship_epoch = self
            .storage
            .current_relationship_epoch(installation_id)?
            .saturating_add(1);
        self.storage
            .apply_relationship_transition(RelationshipTransition::Remove {
                installation_id: installation_id.to_owned(),
                removed_at,
                preserve_history,
                removal_id: removal_id.clone(),
                relationship_epoch,
            })?;
        Ok(FeatureResult::changed(
            RelationshipRemoval {
                removal_id,
                relationship_epoch,
            },
            relationship_changes(),
        ))
    }

    pub fn apply_remote_removal(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        if installation_id.trim().is_empty() || removal_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "relationship removal identifiers must not be empty".to_owned(),
            ));
        }
        self.storage.apply_relationship_transition(
            RelationshipTransition::ApplyRemoteRemoval {
                installation_id: installation_id.to_owned(),
                remote_removed_at: removed_at,
                removal_id: removal_id.to_owned(),
                relationship_epoch,
            },
        )?;
        Ok(FeatureResult::changed((), relationship_changes()))
    }

    pub fn begin_verified(
        &mut self,
        installation_id: &str,
        boundary_at: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.storage.apply_relationship_transition(
            RelationshipTransition::BeginVerified {
                installation_id: installation_id.to_owned(),
                boundary_at,
            },
        )?;
        Ok(FeatureResult::changed((), relationship_changes()))
    }

    pub fn apply(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.storage.apply_relationship_transition(transition)?;
        Ok(FeatureResult::changed((), relationship_changes()))
    }
}

fn relationship_changes() -> ChangeSet {
    ChangeSet::section(
        ChangeSections::RELATIONSHIPS
            .union(ChangeSections::CONTACTS)
            .union(ChangeSections::CONVERSATIONS)
            .union(ChangeSections::MESSAGES),
    )
}
