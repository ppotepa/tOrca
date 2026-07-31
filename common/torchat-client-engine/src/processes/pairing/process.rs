use std::fmt;

use super::{PairingProcessAction, PairingProcessEvent, PairingProcessState};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingProcess {
    pub pairing_id: String,
    pub peer_installation_id: Option<String>,
    pub state: PairingProcessState,
    pub generation: u64,
    pub last_error: Option<String>,
    pub updated_at_ms: i64,
}

impl PairingProcess {
    pub fn new(pairing_id: impl Into<String>, updated_at_ms: i64) -> Self {
        Self {
            pairing_id: pairing_id.into(),
            peer_installation_id: None,
            state: PairingProcessState::CodeSubmitted,
            generation: 0,
            last_error: None,
            updated_at_ms,
        }
    }

    pub fn apply(
        &mut self,
        event: PairingProcessEvent,
        now_ms: i64,
    ) -> Result<Vec<PairingProcessAction>, InvalidPairingTransition> {
        if self.state.terminal() {
            return Err(InvalidPairingTransition {
                state: self.state,
                event,
            });
        }

        let (next, actions, error) = transition(self.state, &event).ok_or_else(|| {
            InvalidPairingTransition {
                state: self.state,
                event: event.clone(),
            }
        })?;
        self.state = next;
        self.generation = self.generation.saturating_add(1);
        self.updated_at_ms = now_ms;
        self.last_error = error;
        Ok(actions)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvalidPairingTransition {
    pub state: PairingProcessState,
    pub event: PairingProcessEvent,
}

impl fmt::Display for InvalidPairingTransition {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "pairing event {:?} is invalid for state {:?}",
            self.event, self.state
        )
    }
}

impl std::error::Error for InvalidPairingTransition {}

fn transition(
    state: PairingProcessState,
    event: &PairingProcessEvent,
) -> Option<(
    PairingProcessState,
    Vec<PairingProcessAction>,
    Option<String>,
)> {
    use PairingProcessAction as Action;
    use PairingProcessEvent as Event;
    use PairingProcessState as State;

    let transition = match (state, event) {
        (State::CodeSubmitted, Event::RemoteRequestObserved) => {
            (State::RequestPending, vec![Action::ScheduleRecovery])
        }
        (State::RequestPending, Event::OfferReceived) => {
            (State::OfferReceived, vec![Action::NotifyUser])
        }
        (State::OfferReceived, Event::OfferPrepared) => {
            (State::OfferPrepared, vec![Action::EnqueueOffer])
        }
        (State::OfferPrepared, Event::OfferQueued) => {
            (State::OfferQueued, vec![Action::ScheduleRecovery])
        }
        (State::OfferQueued, Event::OfferAcknowledged) => {
            (State::OfferAcknowledged, Vec::new())
        }
        (State::RequestPending | State::OfferAcknowledged, Event::WelcomeReceived) => {
            (State::WelcomeReceived, Vec::new())
        }
        (State::WelcomeReceived, Event::WelcomeValidated) => (
            State::WelcomeCommitted,
            vec![Action::CommitContact, Action::EnqueueContactConfirmation],
        ),
        (State::WelcomeCommitted, Event::ContactConfirmationQueued) => (
            State::ContactConfirmationQueued,
            vec![Action::ScheduleRecovery],
        ),
        (State::ContactConfirmationQueued, Event::ContactCommitted) => (
            State::ContactCommitted,
            vec![Action::CreateConversation, Action::StartEndpointExchange],
        ),
        (State::ContactCommitted, Event::ConfirmationDelivered) => (
            State::EndpointExchangePending,
            vec![Action::StartEndpointExchange],
        ),
        (State::EndpointExchangePending, Event::EndpointVerified) => {
            (State::Completed, vec![Action::NotifyUser])
        }
        (_, Event::RejectRequested) => (State::Rejected, vec![Action::NotifyUser]),
        (_, Event::CancelRequested) => (State::Cancelled, vec![Action::NotifyUser]),
        (_, Event::Expired) => (State::Expired, vec![Action::NotifyUser]),
        (_, Event::FailureObserved { reason }) => {
            return Some((
                State::Failed,
                vec![Action::NotifyUser],
                Some(reason.clone()),
            ));
        }
        _ => return None,
    };

    Some((transition.0, transition.1, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incoming_pairing_reaches_endpoint_exchange_and_completion() {
        let mut process = PairingProcess::new("pairing-1", 0);
        process
            .apply(PairingProcessEvent::RemoteRequestObserved, 1)
            .unwrap();
        process
            .apply(PairingProcessEvent::OfferReceived, 2)
            .unwrap();
        process
            .apply(PairingProcessEvent::OfferPrepared, 3)
            .unwrap();
        process
            .apply(PairingProcessEvent::OfferQueued, 4)
            .unwrap();
        process
            .apply(PairingProcessEvent::OfferAcknowledged, 5)
            .unwrap();
        process
            .apply(PairingProcessEvent::WelcomeReceived, 6)
            .unwrap();
        process
            .apply(PairingProcessEvent::WelcomeValidated, 7)
            .unwrap();
        process
            .apply(PairingProcessEvent::ContactConfirmationQueued, 8)
            .unwrap();
        process
            .apply(PairingProcessEvent::ContactCommitted, 9)
            .unwrap();
        process
            .apply(PairingProcessEvent::ConfirmationDelivered, 10)
            .unwrap();
        let actions = process
            .apply(PairingProcessEvent::EndpointVerified, 11)
            .unwrap();

        assert_eq!(process.state, PairingProcessState::Completed);
        assert_eq!(process.generation, 11);
        assert_eq!(actions, vec![PairingProcessAction::NotifyUser]);
    }

    #[test]
    fn terminal_process_rejects_late_events() {
        let mut process = PairingProcess::new("pairing-2", 0);
        process
            .apply(PairingProcessEvent::CancelRequested, 1)
            .unwrap();

        assert!(
            process
                .apply(PairingProcessEvent::RemoteRequestObserved, 2)
                .is_err()
        );
    }

    #[test]
    fn failure_preserves_reason() {
        let mut process = PairingProcess::new("pairing-3", 0);
        process
            .apply(
                PairingProcessEvent::FailureObserved {
                    reason: "invalid welcome signature".to_owned(),
                },
                1,
            )
            .unwrap();

        assert_eq!(process.state, PairingProcessState::Failed);
        assert_eq!(
            process.last_error.as_deref(),
            Some("invalid welcome signature")
        );
    }
}
