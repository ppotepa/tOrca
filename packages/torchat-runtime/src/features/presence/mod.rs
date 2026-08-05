use crate::{ChangeSections, ChangeSet, FeatureResult, RuntimeEvent, RuntimeSession};

pub struct PresenceFeature<'a> {
    session: &'a mut RuntimeSession,
}

impl<'a> PresenceFeature<'a> {
    pub fn new(session: &'a mut RuntimeSession) -> Self {
        Self { session }
    }

    pub fn publish(&mut self, event: RuntimeEvent) -> FeatureResult<()> {
        self.session.push_event(event);
        FeatureResult::changed(
            (),
            ChangeSet::section(ChangeSections::PRESENCE),
        )
    }
}
