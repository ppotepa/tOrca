use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ChangeSections(u16);

impl ChangeSections {
    pub const NONE: Self = Self(0);
    pub const PROFILE: Self = Self(1 << 0);
    pub const PAIRINGS: Self = Self(1 << 1);
    pub const CONTACTS: Self = Self(1 << 2);
    pub const RELATIONSHIPS: Self = Self(1 << 3);
    pub const CONVERSATIONS: Self = Self(1 << 4);
    pub const MESSAGES: Self = Self(1 << 5);
    pub const RECEIPTS: Self = Self(1 << 6);
    pub const PRESENCE: Self = Self(1 << 7);
    pub const TRANSPORT: Self = Self(1 << 8);
    pub const CAPABILITIES: Self = Self(1 << 9);
    pub const OPERATIONS: Self = Self(1 << 10);

    pub const fn contains(self, section: Self) -> bool {
        self.0 & section.0 == section.0
    }

    pub fn insert(&mut self, section: Self) {
        self.0 |= section.0;
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedEntities {
    pub pairing_ids: BTreeSet<String>,
    pub contact_ids: BTreeSet<String>,
    pub conversation_ids: BTreeSet<String>,
    pub message_ids: BTreeSet<String>,
    pub operation_ids: BTreeSet<String>,
}

impl ChangedEntities {
    pub fn merge(&mut self, other: Self) {
        self.pairing_ids.extend(other.pairing_ids);
        self.contact_ids.extend(other.contact_ids);
        self.conversation_ids.extend(other.conversation_ids);
        self.message_ids.extend(other.message_ids);
        self.operation_ids.extend(other.operation_ids);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeSet {
    pub sections: ChangeSections,
    pub entities: ChangedEntities,
}

impl ChangeSet {
    pub fn none() -> Self {
        Self::default()
    }

    pub fn section(section: ChangeSections) -> Self {
        Self {
            sections: section,
            entities: ChangedEntities::default(),
        }
    }

    pub fn merge(&mut self, other: Self) {
        self.sections.insert(other.sections);
        self.entities.merge(other.entities);
    }

    pub fn with_pairing(mut self, id: impl Into<String>) -> Self {
        self.sections.insert(ChangeSections::PAIRINGS);
        self.entities.pairing_ids.insert(id.into());
        self
    }

    pub fn with_contact(mut self, id: impl Into<String>) -> Self {
        self.sections.insert(ChangeSections::CONTACTS);
        self.entities.contact_ids.insert(id.into());
        self
    }

    pub fn with_conversation(mut self, id: impl Into<String>) -> Self {
        self.sections.insert(ChangeSections::CONVERSATIONS);
        self.entities.conversation_ids.insert(id.into());
        self
    }

    pub fn with_message(mut self, id: impl Into<String>) -> Self {
        self.sections.insert(ChangeSections::MESSAGES);
        self.entities.message_ids.insert(id.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DomainEffect {
    DeliverPairing { pairing_id: String },
    DeliverMessage { message_id: String },
    SendReceipt { message_id: String },
    RefreshPeer { contact_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeatureResult<T> {
    pub value: T,
    pub changes: ChangeSet,
    pub effects: Vec<DomainEffect>,
}

impl<T> FeatureResult<T> {
    pub fn unchanged(value: T) -> Self {
        Self {
            value,
            changes: ChangeSet::default(),
            effects: Vec::new(),
        }
    }

    pub fn changed(value: T, changes: ChangeSet) -> Self {
        Self {
            value,
            changes,
            effects: Vec::new(),
        }
    }

    pub fn with_effect(mut self, effect: DomainEffect) -> Self {
        self.effects.push(effect);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommittedChange<T> {
    pub value: T,
    pub changes: ChangeSet,
    pub effects: Vec<DomainEffect>,
    pub revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChangePublisher {
    revision: u64,
}

impl ChangePublisher {
    pub const fn new(revision: u64) -> Self {
        Self { revision }
    }

    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Commits persistence first, then advances exactly one projection revision.
    /// Effects are returned to the caller and must be scheduled afterwards.
    pub fn commit<T, E>(
        &mut self,
        result: FeatureResult<T>,
        commit: impl FnOnce() -> Result<(), E>,
    ) -> Result<CommittedChange<T>, E> {
        commit()?;
        self.revision = self.revision.saturating_add(1);
        Ok(CommittedChange {
            value: result.value,
            changes: result.changes,
            effects: result.effects,
            revision: self.revision,
        })
    }
}
