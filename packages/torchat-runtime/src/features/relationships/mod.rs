use crate::{
    ChangeSections, ChangeSet, FeatureResult, RelationshipStorage, RelationshipTransition,
    RuntimeResult,
};

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

    pub fn apply(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.storage.apply_relationship_transition(transition)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::section(
                ChangeSections::RELATIONSHIPS
                    .union(ChangeSections::CONTACTS)
                    .union(ChangeSections::CONVERSATIONS),
            ),
        ))
    }
}
