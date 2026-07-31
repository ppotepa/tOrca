use torchat_client_runtime::ApplicationSnapshot;

use crate::DomainEvent;

use super::{ApplicationSnapshotPatch, ProjectionPatchError};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionUpdate {
    Rebuilt(ApplicationSnapshot),
    Patched(ApplicationSnapshotPatch),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApplicationSnapshotProjector {
    snapshot: ApplicationSnapshot,
}

impl ApplicationSnapshotProjector {
    pub fn new(snapshot: ApplicationSnapshot) -> Self {
        Self {
            snapshot: snapshot.normalize(),
        }
    }

    pub fn snapshot(&self) -> &ApplicationSnapshot {
        &self.snapshot
    }

    pub fn database_identity(&self) -> &str {
        &self.snapshot.identity.installation_id
    }

    pub fn apply(
        &mut self,
        event: DomainEvent,
        created_at_ms: i64,
    ) -> Result<ProjectionUpdate, ProjectionPatchError> {
        if let DomainEvent::SnapshotRebuilt { snapshot } = &event {
            self.snapshot = snapshot.clone().normalize();
            return Ok(ProjectionUpdate::Rebuilt(self.snapshot.clone()));
        }

        let base_generation = self.snapshot.generation;
        let mut patch = ApplicationSnapshotPatch {
            database_identity: self.database_identity().to_owned(),
            base_generation,
            generation: base_generation.saturating_add(1),
            created_at_ms,
            ..ApplicationSnapshotPatch::default()
        };

        match event {
            DomainEvent::ProfileChanged { profile } => patch.profile = Some(profile),
            DomainEvent::ContactUpserted { contact } => patch.contacts_upsert.push(contact),
            DomainEvent::ContactRemoved { installation_id } => {
                patch.contacts_removed.push(installation_id)
            }
            DomainEvent::ConversationUpserted { conversation }
            | DomainEvent::MessageConversationChanged { conversation } => {
                patch.conversations_upsert.push(conversation)
            }
            DomainEvent::ConversationRemoved { conversation_id } => {
                patch.conversations_removed.push(conversation_id)
            }
            DomainEvent::PairingSummaryChanged { summary } => {
                patch.pairing_summary = Some(summary)
            }
            DomainEvent::PeerEndpointAvailabilityChanged { available } => {
                patch.peer_endpoint_available = Some(available)
            }
            DomainEvent::ConnectionChanged { .. } => {}
            DomainEvent::SnapshotRebuilt { .. } => unreachable!("handled before patch creation"),
        }

        self.snapshot = patch.apply_to(&self.snapshot)?;
        Ok(ProjectionUpdate::Patched(patch))
    }
}

#[cfg(test)]
mod tests {
    use torchat_client_runtime::{
        ApplicationSnapshot, PairingSummary, RuntimeIdentity, UiCheckpoint,
        APPLICATION_SNAPSHOT_SCHEMA_VERSION,
    };

    use super::*;

    fn snapshot() -> ApplicationSnapshot {
        ApplicationSnapshot {
            schema_version: APPLICATION_SNAPSHOT_SCHEMA_VERSION,
            generation: 7,
            created_at_ms: 10,
            identity: RuntimeIdentity::from_parts(
                "local".to_owned(),
                "public".to_owned(),
                "fingerprint".to_owned(),
            ),
            profile: None,
            contacts: Vec::new(),
            conversations: Vec::new(),
            pairing_summary: PairingSummary::default(),
            peer_endpoint_available: false,
            ui_checkpoint: UiCheckpoint::default(),
        }
    }

    #[test]
    fn projector_emits_monotonic_patch_and_updates_snapshot() {
        let mut projector = ApplicationSnapshotProjector::new(snapshot());
        let update = projector
            .apply(
                DomainEvent::PeerEndpointAvailabilityChanged { available: true },
                20,
            )
            .unwrap();

        assert!(matches!(
            update,
            ProjectionUpdate::Patched(ApplicationSnapshotPatch {
                base_generation: 7,
                generation: 8,
                peer_endpoint_available: Some(true),
                ..
            })
        ));
        assert_eq!(projector.snapshot().generation, 8);
        assert!(projector.snapshot().peer_endpoint_available);
    }

    #[test]
    fn full_rebuild_repairs_generation_without_patch() {
        let mut projector = ApplicationSnapshotProjector::new(snapshot());
        let mut rebuilt = snapshot();
        rebuilt.generation = 100;

        let update = projector
            .apply(DomainEvent::SnapshotRebuilt { snapshot: rebuilt }, 0)
            .unwrap();

        assert!(matches!(update, ProjectionUpdate::Rebuilt(_)));
        assert_eq!(projector.snapshot().generation, 100);
    }
}
