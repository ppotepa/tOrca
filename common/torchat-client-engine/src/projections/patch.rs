use std::fmt;

use torchat_client_runtime::{
    ApplicationSnapshot, ContactRecord, ConversationSummary, PairingSummary, RuntimeProfile,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ApplicationSnapshotPatch {
    pub database_identity: String,
    pub base_generation: u64,
    pub generation: u64,
    pub created_at_ms: i64,
    pub profile: Option<RuntimeProfile>,
    pub contacts_upsert: Vec<ContactRecord>,
    pub contacts_removed: Vec<String>,
    pub conversations_upsert: Vec<ConversationSummary>,
    pub conversations_removed: Vec<String>,
    pub pairing_summary: Option<PairingSummary>,
    pub peer_endpoint_available: Option<bool>,
}

impl ApplicationSnapshotPatch {
    pub fn apply_to(
        &self,
        snapshot: &ApplicationSnapshot,
    ) -> Result<ApplicationSnapshot, ProjectionPatchError> {
        let current_identity = snapshot.identity.installation_id.as_str();
        if current_identity != self.database_identity {
            return Err(ProjectionPatchError::IdentityMismatch {
                current: current_identity.to_owned(),
                patch: self.database_identity.clone(),
            });
        }
        if snapshot.generation != self.base_generation {
            return Err(ProjectionPatchError::GenerationGap {
                current: snapshot.generation,
                base: self.base_generation,
                next: self.generation,
            });
        }
        if self.generation <= self.base_generation {
            return Err(ProjectionPatchError::NonMonotonicGeneration {
                base: self.base_generation,
                next: self.generation,
            });
        }

        let mut next = snapshot.clone();
        next.generation = self.generation;
        next.created_at_ms = self.created_at_ms;
        if let Some(profile) = &self.profile {
            next.profile = Some(profile.clone());
        }
        for removed in &self.contacts_removed {
            next.contacts
                .retain(|contact| contact.installation_id != *removed);
        }
        for contact in &self.contacts_upsert {
            next.contacts
                .retain(|current| current.installation_id != contact.installation_id);
            next.contacts.push(contact.clone());
        }
        for removed in &self.conversations_removed {
            next.conversations
                .retain(|conversation| conversation.id != *removed);
        }
        for conversation in &self.conversations_upsert {
            next.conversations
                .retain(|current| current.id != conversation.id);
            next.conversations.push(conversation.clone());
        }
        if let Some(summary) = &self.pairing_summary {
            next.pairing_summary = summary.clone();
        }
        if let Some(available) = self.peer_endpoint_available {
            next.peer_endpoint_available = available;
        }
        Ok(next.normalize())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionPatchError {
    IdentityMismatch {
        current: String,
        patch: String,
    },
    GenerationGap {
        current: u64,
        base: u64,
        next: u64,
    },
    NonMonotonicGeneration {
        base: u64,
        next: u64,
    },
}

impl fmt::Display for ProjectionPatchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IdentityMismatch { current, patch } => write!(
                formatter,
                "snapshot identity mismatch: current={current} patch={patch}",
            ),
            Self::GenerationGap {
                current,
                base,
                next,
            } => write!(
                formatter,
                "snapshot generation gap: current={current} base={base} next={next}",
            ),
            Self::NonMonotonicGeneration { base, next } => write!(
                formatter,
                "snapshot generation is not monotonic: base={base} next={next}",
            ),
        }
    }
}

impl std::error::Error for ProjectionPatchError {}
