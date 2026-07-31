use torchat_client_runtime::{
    ContactTransportPolicy, PeerConnectionStatus, PeerEndpointStatus,
};

use super::DeliveryKind;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RoutingContext {
    pub policy: ContactTransportPolicy,
    pub peer_endpoint: PeerEndpointStatus,
    pub peer_connection: PeerConnectionStatus,
    pub relay_available: bool,
    pub network_online: bool,
    pub delivery_kind: DeliveryKind,
    pub attempt_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RoutingDecision {
    Peer,
    Relay,
    PeerThenRelay { fallback_after_ms: u64 },
    WaitForPeerEndpoint,
    WaitForNetwork,
    PermanentFailure { reason: String },
}

pub struct TransportRouter;

impl TransportRouter {
    pub fn route(context: &RoutingContext) -> RoutingDecision {
        if !context.network_online {
            return RoutingDecision::WaitForNetwork;
        }

        match context.policy {
            ContactTransportPolicy::RelayOnly => {
                if context.relay_available {
                    RoutingDecision::Relay
                } else {
                    RoutingDecision::WaitForNetwork
                }
            }
            ContactTransportPolicy::PeerOnly => Self::peer_only(context),
            ContactTransportPolicy::PeerWithRelayFallback => Self::peer_with_fallback(context),
        }
    }

    fn peer_only(context: &RoutingContext) -> RoutingDecision {
        match (context.peer_endpoint, context.peer_connection) {
            (PeerEndpointStatus::Invalid, _) => RoutingDecision::PermanentFailure {
                reason: "peer endpoint is invalid".to_owned(),
            },
            (PeerEndpointStatus::Verified, PeerConnectionStatus::Connected) => {
                RoutingDecision::Peer
            }
            (PeerEndpointStatus::Verified, _) => RoutingDecision::Peer,
            _ => RoutingDecision::WaitForPeerEndpoint,
        }
    }

    fn peer_with_fallback(context: &RoutingContext) -> RoutingDecision {
        match (context.peer_endpoint, context.peer_connection) {
            (PeerEndpointStatus::Verified, PeerConnectionStatus::Connected) => {
                RoutingDecision::Peer
            }
            (PeerEndpointStatus::Verified, _) if context.relay_available => {
                RoutingDecision::PeerThenRelay {
                    fallback_after_ms: 8_000,
                }
            }
            (PeerEndpointStatus::Verified, _) => RoutingDecision::Peer,
            (PeerEndpointStatus::Invalid, _) if context.relay_available => {
                RoutingDecision::Relay
            }
            (_, _) if context.relay_available => RoutingDecision::Relay,
            _ => RoutingDecision::WaitForPeerEndpoint,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(policy: ContactTransportPolicy) -> RoutingContext {
        RoutingContext {
            policy,
            peer_endpoint: PeerEndpointStatus::Verified,
            peer_connection: PeerConnectionStatus::Connected,
            relay_available: true,
            network_online: true,
            delivery_kind: DeliveryKind::Message,
            attempt_count: 0,
        }
    }

    #[test]
    fn peer_only_never_selects_relay() {
        let mut value = context(ContactTransportPolicy::PeerOnly);
        value.peer_endpoint = PeerEndpointStatus::Missing;
        assert_eq!(
            TransportRouter::route(&value),
            RoutingDecision::WaitForPeerEndpoint,
        );
    }

    #[test]
    fn relay_only_never_selects_peer() {
        let value = context(ContactTransportPolicy::RelayOnly);
        assert_eq!(TransportRouter::route(&value), RoutingDecision::Relay);
    }

    #[test]
    fn fallback_policy_uses_peer_then_relay_while_peer_connects() {
        let mut value = context(ContactTransportPolicy::PeerWithRelayFallback);
        value.peer_connection = PeerConnectionStatus::Connecting;
        assert_eq!(
            TransportRouter::route(&value),
            RoutingDecision::PeerThenRelay {
                fallback_after_ms: 8_000,
            },
        );
    }
}
