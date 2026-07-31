use torchat_client_runtime::ApplicationSnapshot;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectionDiagnostics {
    pub database_identity: String,
    pub generation: u64,
    pub contact_count: usize,
    pub conversation_count: usize,
    pub pending_pairing_count: u32,
    pub peer_endpoint_available: bool,
}

impl From<&ApplicationSnapshot> for ProjectionDiagnostics {
    fn from(snapshot: &ApplicationSnapshot) -> Self {
        Self {
            database_identity: snapshot.identity.installation_id.clone(),
            generation: snapshot.generation,
            contact_count: snapshot.contacts.len(),
            conversation_count: snapshot.conversations.len(),
            pending_pairing_count: snapshot
                .pairing_summary
                .pending_inbox
                .saturating_add(snapshot.pairing_summary.pending_outbox),
            peer_endpoint_available: snapshot.peer_endpoint_available,
        }
    }
}
