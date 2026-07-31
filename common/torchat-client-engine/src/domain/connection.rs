use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EngineConnectionState {
    LocalOnly,
    WaitingForNetwork,
    WaitingForTor,
    TorReady,
    RelayConnecting,
    RelayAuthenticating,
    RelayReady,
    PeerListenerReady,
    OnionPublishing,
    CommunicationReady,
    Degraded,
    Backoff,
    Stopped,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionEvent {
    NetworkAvailable,
    NetworkLost,
    TorEndpointAvailable,
    TorEndpointLost,
    RelayConnecting,
    RelayAuthenticating,
    RelayConnected,
    RelayDisconnected,
    PeerListenerBound,
    OnionPublishing,
    OnionAvailable,
    OnionLost,
    BackoffElapsed,
    Stop,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidConnectionTransition {
    pub current: EngineConnectionState,
    pub event: ConnectionEvent,
}

impl fmt::Display for InvalidConnectionTransition {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "invalid connection transition: {:?} + {:?}",
            self.current, self.event,
        )
    }
}

impl std::error::Error for InvalidConnectionTransition {}

pub fn transition_connection(
    current: EngineConnectionState,
    event: ConnectionEvent,
) -> Result<EngineConnectionState, InvalidConnectionTransition> {
    use ConnectionEvent as Event;
    use EngineConnectionState as State;

    let next = match (current, event) {
        (_, Event::Stop) => State::Stopped,
        (_, Event::NetworkLost) => State::WaitingForNetwork,
        (State::WaitingForNetwork, Event::NetworkAvailable) => State::WaitingForTor,
        (State::LocalOnly | State::WaitingForTor, Event::TorEndpointAvailable) => State::TorReady,
        (_, Event::TorEndpointLost) => State::WaitingForTor,
        (State::TorReady | State::Backoff | State::Degraded, Event::RelayConnecting) => {
            State::RelayConnecting
        }
        (State::RelayConnecting, Event::RelayAuthenticating) => State::RelayAuthenticating,
        (State::RelayConnecting | State::RelayAuthenticating, Event::RelayConnected) => {
            State::RelayReady
        }
        (
            State::RelayConnecting
            | State::RelayAuthenticating
            | State::RelayReady
            | State::CommunicationReady,
            Event::RelayDisconnected,
        ) => State::Backoff,
        (State::Backoff, Event::BackoffElapsed) => State::RelayConnecting,
        (State::TorReady | State::RelayReady, Event::PeerListenerBound) => State::PeerListenerReady,
        (State::PeerListenerReady, Event::OnionPublishing) => State::OnionPublishing,
        (State::OnionPublishing | State::RelayReady, Event::OnionAvailable) => {
            State::CommunicationReady
        }
        (State::CommunicationReady | State::OnionPublishing, Event::OnionLost) => State::Degraded,
        _ => return Err(InvalidConnectionTransition { current, event }),
    };
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_connection_path_reaches_communication_ready() {
        let mut state = EngineConnectionState::WaitingForNetwork;
        for event in [
            ConnectionEvent::NetworkAvailable,
            ConnectionEvent::TorEndpointAvailable,
            ConnectionEvent::RelayConnecting,
            ConnectionEvent::RelayAuthenticating,
            ConnectionEvent::RelayConnected,
            ConnectionEvent::PeerListenerBound,
            ConnectionEvent::OnionPublishing,
            ConnectionEvent::OnionAvailable,
        ] {
            state = transition_connection(state, event).unwrap();
        }
        assert_eq!(state, EngineConnectionState::CommunicationReady);
    }

    #[test]
    fn network_loss_fences_every_active_state() {
        assert_eq!(
            transition_connection(
                EngineConnectionState::CommunicationReady,
                ConnectionEvent::NetworkLost,
            )
            .unwrap(),
            EngineConnectionState::WaitingForNetwork,
        );
    }
}
