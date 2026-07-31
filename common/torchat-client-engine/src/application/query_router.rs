use crate::EngineQuery;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueryProjection {
    Identity,
    Profile,
    Pairing,
    Contacts,
    Conversations,
    Messages,
    PeerEndpoint,
    ApplicationSnapshot,
    Diagnostics,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QueryRoute {
    pub projection: QueryProjection,
    pub local_only: bool,
}

pub struct QueryRouter;

impl QueryRouter {
    pub const fn route(query: &EngineQuery) -> QueryRoute {
        let projection = match query {
            EngineQuery::GetIdentity => QueryProjection::Identity,
            EngineQuery::GetProfile => QueryProjection::Profile,
            EngineQuery::GetPairingInbox | EngineQuery::GetPairingOutbox => {
                QueryProjection::Pairing
            }
            EngineQuery::ListContacts => QueryProjection::Contacts,
            EngineQuery::ListConversations => QueryProjection::Conversations,
            EngineQuery::ListMessages { .. } => QueryProjection::Messages,
            EngineQuery::GetPeerEndpoint => QueryProjection::PeerEndpoint,
            EngineQuery::GetApplicationSnapshot => QueryProjection::ApplicationSnapshot,
            EngineQuery::GetDiagnostics => QueryProjection::Diagnostics,
        };
        QueryRoute {
            projection,
            local_only: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_query_is_explicitly_local_only() {
        let queries = [
            EngineQuery::GetIdentity,
            EngineQuery::GetProfile,
            EngineQuery::GetPairingInbox,
            EngineQuery::GetPairingOutbox,
            EngineQuery::ListContacts,
            EngineQuery::ListConversations,
            EngineQuery::GetPeerEndpoint,
            EngineQuery::GetApplicationSnapshot,
            EngineQuery::GetDiagnostics,
        ];

        assert!(queries.iter().all(|query| QueryRouter::route(query).local_only));
    }
}
