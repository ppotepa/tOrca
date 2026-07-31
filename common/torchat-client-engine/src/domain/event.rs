use torchat_client_runtime::{
    ApplicationSnapshot, ContactRecord, ConversationSummary, PairingSummary, RuntimeProfile,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DomainEvent {
    SnapshotRebuilt {
        snapshot: ApplicationSnapshot,
    },
    ProfileChanged {
        profile: RuntimeProfile,
    },
    ContactUpserted {
        contact: ContactRecord,
    },
    ContactRemoved {
        installation_id: String,
    },
    ConversationUpserted {
        conversation: ConversationSummary,
    },
    ConversationRemoved {
        conversation_id: String,
    },
    MessageConversationChanged {
        conversation: ConversationSummary,
    },
    PairingSummaryChanged {
        summary: PairingSummary,
    },
    PeerEndpointAvailabilityChanged {
        available: bool,
    },
    ConnectionChanged {
        generation: u64,
        detail: String,
    },
}

impl DomainEvent {
    pub const fn affects_application_snapshot(&self) -> bool {
        true
    }
}
